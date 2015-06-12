require 'sinatra'
require 'sinatra/activerecord'
require 'will_paginate'
require 'will_paginate/active_record'
require './config/env'
require 'sinatra/recaptcha'
require 'bcrypt'

# wow models
require './models/Quote'
require './models/User'

configure do
  enable :sessions

  set :auth_flags, {
    :post_quotes => 1,
    :edit_quotes => 2,
    :delete_quotes => 4,
    :list_users => 8,
    :approve_quotes => 16,
    :set_flags => 32
  }

  set(:auth) do |*roles|
    condition do
      # new pseudo-role: logged_in
      if roles.include? :logged_in
        redirect '/user/login' unless session[:username]
        return
      end

      unless session[:username]
        redirect '/user/login'
        return
      end

      curr_flags = session[:flags]
      auth_flags = settings.auth_flags

      allowed = roles.length > 0

      roles.each do |role|
        # skip the :logged_in role
        next if role == :logged_in
        flag_exists = (curr_flags & auth_flags[role]) != 0
        allowed = allowed && flag_exists
      end
      redirect '/user/login' unless allowed
    end

    Sinatra::ReCaptcha.public_key = "6LeTMwgTAAAAAGbcCK0A3l-oKsqeHvvgzyuVO6Yz"
    abort "Set $RECAPTCHA_SECRET to your recaptcha secret!" unless ENV['RECAPTCHA_SECRET']
    Sinatra::ReCaptcha.private_key = ENV['RECAPTCHA_SECRET']
  end

  # Open a new file for moderation action logging
  $moderationLog = File.new './log/moderation.log', 'a'
  $moderationLog.sync = true

  def logModAction(name, action, on)
    time = DateTime.now.iso8601
    $moderationLog.puts "time=#{time} name=#{name} action=#{action} on=#{on}"
  end

  set :logModAction, lambda { |name, act, on| logModAction(name, act, on) }

  set :public_folder, File.dirname(__FILE__) + '/static'

  set :recaptcha_secret, ENV['RECAPTCHA_SECRET']
end

before do
  @username = session[:username] or nil
  @loggedIn = @username != nil
  @flags    = session[:flags]

  if @loggedIn
    @userFlags = []
    settings.auth_flags.each do |flag, bitmask|
      if (session[:flags] & bitmask) != 0
        @userFlags << flag
      end
    end
  end
end

helpers do
  def esc text
    Rack::Utils.escape_html text
  end
end


#
# Viewing quotes
#

get '/' do
  erb :index
end


# Get which quote?
get '/quote/:id' do
  pass if params[:id] == 'new'
  @quote = Quote.where(:id => params[:id].to_i).first

  if (@quote && @quote.approved) or
     (@quote && @loggedIn && @userFlags.include?(:approve_quotes))
    erb :'quote/view'
  else
    erb :error, locals: { message: "No such quote!" }
  end
end

# Get a list of quotes with a sort-by action
get '/quotes/:sortby' do
  pass unless params[:sortby]
end

# Get a list of ~10 quotes
get '/quotes/' do
  page = params[:page] == 0 ? 1 : params[:page]
  @quotes = Quote.where(:approved => true).page(params[:page])
  erb :'quote/list'
end

get '/quote' do
  redirect '/quotes/'
end

get '/quotes' do
  redirect '/quotes/'
end

#
# Logins
#

get '/user/login' do
  erb :'user/login'
end

get '/login' do
  redirect '/user/login'
end

post '/user/login' do

  unless session.empty?
    erb :error, locals: {message: "You're already logged in!"}
  end
  unless params[:name] and params[:password]
    erb :error, locals: {message: "Invalid request body!"}
  end

  user = User.where(name: params[:name]).first

  if user
    pw_hash = BCrypt::Password.new (user[:password])

    if pw_hash == params[:password]
      session[:username] = user[:name]
      session[:flags] = user[:flags]
      session[:user_id] = user[:id]

      erb "<h2> Successfully logged in as #{user.name}! </h2>"

    else
      erb :error, locals: { message: "User/password invalid :(" }
    end
  else
    erb :error, locals: {message: "No such user!"}
  end
end

get '/user/register' do
  erb :'user/register'
end

post '/user/register' do

  unless params[:user] and params[:user][:name] and params[:user][:password]
    erb :error, locals: {message: 'Invalid request body!'}
  end

  erb :error, locals: {message: "Recaptcha failed :o"} unless recaptcha_correct?

  puts 'Creating new user with details:'
  p params[:user]

  params[:user][:flags] = 0
  params[:user][:password] = BCrypt::Password.create(params[:user][:password])

  user = User.new params[:user]

  if user.save
    puts 'Success!'
    erb "<h2>Successfully registered with username #{params[:user][:name]}!</h2>"
  else
    puts 'Failure!'
    erb :error, locals: {message: "Error saving your user!"}
  end
end

get '/register' do
  redirect '/user/register'
end

# Users can only view their own settings
get '/user/settings', :auth => [:logged_in] do
  @user = User.find(session[:user_id])

  if @user
    erb :'user/settings'
  else
    erb :error, locals: {message: "Your user was not found :o"}
  end
end

get '/user/logout', :auth => [:logged_in] do
  session.clear
  erb "<h2> Session cleared! </h2>"
end

get '/logout' do
  redirect '/user/logout'
end

get '/user/change_pw', :auth => [:logged_in] do
  @user = User.find(session[:user_id])
  if @user
    erb :'user/change_pw'
  else
    erb :error, locals: {message: "Your user was not found :o"}
  end
end

post '/user/change_pw', :auth => [:logged_in] do
  @user = User.find(session[:user_id])
  if @user
    # Check that the old password is right
    pw_hash = BCrypt::Password.new(@user.password)
    unless pw_hash == params[:password]
      erb :error, locals: {message: "Your old password wasn't correct!"}
    end

    unless params[:password] == params[:password_confirm]
      erb :error, locals: {message: "Two new passwords didn't match!"}
    end

    @user.password = BCrypt::Password.create(params[:password])
    if @user.save
      erb "<h2>New password successfully saved! Re-login to try it out!</h2>"
    else
      erb :error, locals: {message: "Failed to save your password D:"}
    end
  else
    erb :error, locals: {message: "Your user was not found :o"}
  end
end

get '/user/delete', :auth => [:logged_in] do
  erb :'user/delete'
end

post '/user/delete', :auth => [:logged_in] do
  @user = User.find(session[:user_id])
  if @user
    @user.destroy
    session.clear
    erb "<h2>Done! You're now logged out and your user has been deleted.</h2>"
  else
    erb :error, locals: {message: "Your user was not found :o"}
  end
end

#
# Managing quotes
#

get '/quote/new', :auth => [:post_quotes] do
  erb :'quote/add'
end

# Post a new quote, returns link to quote
post '/quote/new', :auth => [:post_quotes] do
  q = params[:quote]

  # no double escaping now!
  # make sure that quote.erb et al keep esc()ing the input then
  # q[:quote]  = esc(q[:quote])
  q[:author] = session[:username]

  mdl = Quote.new q

  if mdl.save
    logModAction(session[:username], ":post_quotes", mdl[:id])
    redirect '/quotes/'
  else
    erb :error, locals: { message: "Error saving the quote!" }
  end
end


# Edit/Delete a quote by ID

get '/quote/:id/edit', :auth => [:edit_quotes] do

  @action = "edit"
  @quote = Quote.find(params[:id].to_i)

  if @quote
    erb :'quote/edit'
  else
    erb :error, locals: { message: "No such quote!" }
  end
end

post '/quote/:id/edit', :auth => [:edit_quotes] do
  unless params[:author] and params[:quote]
    erb :error, locals: {message: "Invalid form data!"}
  end
  quote = Quote.find(params[:id].to_i)

  if quote
    quote.author = params[:author]
    quote.quote  = params[:quote]
    if quote.save
      logModAction(session[:username], ":edit_quotes", params[:id].to_i)
      redirect "/quote/#{params[:id]}"
    else
      erb :error, locals: { message: "Error saving quote!" }
    end
  end
end


get '/quote/:id/delete', :auth => [:delete_quotes] do

  @quote = Quote.find(params[:id].to_i)

  if @quote
    erb :'quote/delete'
  else
    erb :error, locals: { message: "No such quote!" }
  end
end

post '/quote/:id/delete', :auth => [:delete_quotes] do

  quote = Quote.find(params[:id].to_i)

  if quote
    logModAction(session[:username], ":delete_quotes", params[:id].to_i)
    quote.destroy
    erb "<h2> Destroyed quote #{params[:id]} successfully. </h2>"
  else
    erb :error, locals: { message: "Error deleting quote!" }
  end
end

post '/quote/:id/approve', :auth => [:approve_quotes] do
  quote = Quote.find(params[:id].to_i)
  if quote
    quote.approved = true
    if quote.save
      erb "<h2> Successfully saved quote #{params[:id]}! </h2>"
    else
      erb :error, locals: {message: "Error saving quote!" }
    end
  else
    erb :error, locals: {message: "No such quote!"}
  end
end


#
# Managing users
#

get '/user/list', :auth => [:list_users] do
  page = params[:page] == 0 ? 1 : params[:page]
  @users = User.all.page(page)
  erb :'user/list'
end

get '/user/:id/set_flags', :auth => [:set_flags] do
  @id = params[:id]
  erb :'user/set_flags'
end

post '/user/:id/set_flags', :auth => [:set_flags] do
  unless params[:flags]
    erb :error, locals: {message: "Invalid form data! 'flags' needed!"}
  end

  user = User.find(params[:id])

  if user
    user[:flags] = params[:flags].to_i
    if user.save
      logModAction(session[:username], ":set_flags","#{params[:id]} -> #{user[:flags]}")
      erb "<h2> Successfully saved new flags #{user[:flags]} to user #{user[:name]}"
    else
      erb :error, locals: {message: "Error saving user!"}
    end
  else
    erb :error, locals: {message: "No such user!"}
  end
end

# Moderation queue
get '/moderate/queue', :auth => [:approve_quotes] do
  @quotes = Quote.where(:approved => false)
  if @quotes
    erb :'mod/approve_queue'
  else
    erb :error, locals: {message: "Moderation queue clear. :D"}
  end
end
