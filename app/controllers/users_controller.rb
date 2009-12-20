class UsersController < ApplicationController
  before_filter :require_no_user, :only => [:new, :create]
  before_filter :require_user, :only => [:show, :edit, :update]

  def new
    @user = Core::User.new
    flash[:notice] = "Operation not yet supported"
  end

  def create
    @user = Core::User.new
    flash[:notice] = "Operation not yet supported"
    render :action => :new
    # TODO comment in when new users are allowed to sign up
#    @user = Core::User.new(params[:core_user])
#    if @user.save
#      flash[:notice] = "Account registered!"
#      redirect_back_or_default account_url
#    else
#      render :action => :new
#    end
  end

  def show
    @user = @current_user
  end

  def edit
    @user = @current_user
  end

  def update
    @user = @current_user # makes our views "cleaner" and more consistent
    if @user.update_attributes(params[:core_user])
      flash[:notice] = "Account updated!"
      redirect_to account_url
    else
      render :action => :edit
    end
  end
end
