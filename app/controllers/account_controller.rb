# Controller that handles creation and working with user accounts

class AccountController < ApplicationController

  before_filter :require_login, :only => [:edit, :update, :logout, :tags, :mygroups]

  def new
    @new_person = Person.new
  end

  def create
    @new_person = Person.new(params[:new_person])

    if @new_person.save
      flash[:notice] = "Congratulations, #{@new_person.first_name}!  You are now registered with the Modeling Commons.  We're delighted that you've joined us."

      Notifications.deliver_signup(@new_person, params[:new_person][:password])
      session[:person_id] = @new_person.id
      redirect_to :controller => :account, :action => :mypage
    else
      render :action => :new
    end

  end

  def edit
  end

  def tags
  end

  def update
    if params[:person][:password].blank?
      params[:person].delete(:password)
      params[:person].delete(:password_confirmation)
    end

    begin
      @person.update_attributes!(params[:person])
      flash[:notice] = "Successfully updated your account."
      redirect_to :back
    rescue Exception => exception
      flash[:notice] = "Error updating your account: '#{exception.message}'"
      redirect_to :back
    end

  end

  def login
  end

  def login_action
    if params[:email_address].blank? or params[:password].blank?
      flash[:notice] = "You must provide an e-mail address and password in order to log in."
      redirect_to :controller => :account, :action => :login
      return
    end

    @person = Person.find_by_email_address(params[:email_address].strip.downcase)
    if @person.nil?
      logger.warn "Attempted login with non-existent email_address '#{params[:email_address]}'"
      flash[:notice] = "Sorry, but no user exists with that e-mail address and password.  Please try again."
      redirect_to :back
      return
    end

    encrypted_user_input = Person.encrypted_password(@person.salt, params[:password])
    if encrypted_user_input != @person.password
      logger.warn "Attempted login for email_address '#{params[:email_address]}' with incorrect password '#{params[:password]}'"
      flash[:notice] = "Sorry, but no user exists with that e-mail address and password.  Please try again."
      redirect_to :back
      return
    end

    flash[:notice] = "Welcome back to the Commons, #{@person.first_name}!"
    session[:person_id] = @person.id
    redirect_to :controller => :account, :action => :mypage
  end

  def logout
    @person = nil
    session[:person_id] = nil
    flash[:notice] = "You have been logged out.  Please come back soon!"
    redirect_to :controller => :account, :action => :login
  end

  def mypage

    if @person.nil? and params[:id].blank?
      redirect_to :controller => :account, :action => :login
      return
    end

    if params[:id].blank?
      @the_person = @person
    else
      @the_person = Person.find(params[:id].to_i,
                                :include => [:postings, :tags, :tagged_nodes, :nodes])
    end

    how_new_is_new = 6.months.ago

    @questions = Posting.unanswered_questions.select { |question| question.created_at >= how_new_is_new }

    @recent_tags = @the_person.tags.select { |tag| tag.created_at >= how_new_is_new}
    @recent_tagged_models = @the_person.tagged_nodes.select { |tagged_node| tagged_node.created_at >= how_new_is_new}
    @tag_events = [@recent_tags, @recent_tagged_models].flatten.sort_by { |tag| tag.created_at}.reverse
    @tag_events = @tag_events[0..9] if @tag_events.length > 10

    # Model updates
    @model_events = [ ]
    @group_recent_models = [ ]

    @the_person.models.each do |model|
      if model.updated_at >= how_new_is_new
        @model_events << model 
        @group_recent_models << model if model.group
      end
    end

    @model_events = @model_events.sort_by {|model| model.updated_at}.reverse
    @group_recent_models.sort_by {|model| model.updated_at}.reverse
    @group_model_events = @group_recent_models.select { |model| model.group.members.include?(@person)}

    # most-viewed models
    @most_viewed = LoggedAction.find_by_sql("SELECT COUNT(DISTINCT person_id), node_id
                                                FROM Logged_Actions
                                               WHERE controller = 'browse'
                                                 AND action = 'one_model'
                                                 AND node_id IS NOT NULL
                                                 AND logged_at >= NOW() - interval '3 months'
                                            GROUP BY node_id
                                            ORDER BY count DESC
                                               LIMIT 10;").map { |la| [la.node, la.count]}

    # most-downloaded models
    @most_downloaded = LoggedAction.find_by_sql("SELECT COUNT(DISTINCT person_id), node_id
                                                   FROM Logged_Actions
                                                  WHERE controller = 'browse'
                                                    AND action = 'download_model'
                                                    AND node_id IS NOT NULL
                                                    AND logged_at >= NOW() - interval '3 months'
                                               GROUP BY node_id
                                               ORDER BY count DESC
                                                  LIMIT 10;").map { |la| [la.node, la.count]}

    # most-applied tags
    @most_popular_tags =
      TaggedNode.count(:group => "tag_id",
                       :order => "count_all DESC",
                       :limit => 10).map { |tag| [Tag.find(tag[0]), tag[1]]}

    # most-recommended models
    @most_recommended_models =
      Recommendation.count(:group => "node_id",
                           :order => "count_all DESC",
                           :limit => 10).map { |node| [Node.find(node[0]), node[1]]}
  end

  def mygroups
    render :layout => 'plain'
  end

  def reset_password_action
    email_address = params[:email_address].to_s

    if email_address.index('@').nil?
      flash[:notice] = "Sorry, but '#{email_address}' is not a valid e-mail address.  Please try again."
      redirect_to :controller => :account, :action => :send_password
      return
    end

    @person = Person.find_by_email_address(email_address)

    if @person
      new_password = ''
      8.times { new_password << ('a'..'z').to_a.shuffle.first }
      @person.update_attributes!(:password => new_password)

      Notifications.deliver_password_reminder(@person, new_password)
      flash[:notice] = "Your password has been reset.  The new password was sent to your e-mail address."
      redirect_to :controller => :account, :action => :login
    else
      flash[:notice] = "Sorry, but '#{email_address}' is not listed in our system.  Please register."
      redirect_to :back
    end

  end

  def follow
    if params[:id].blank?
      flash[:notice] = "You must indicate the person whose actions you wish to follow."
      logger.warn "[follow] Sending user back; no ID specified"
      redirect_to :back
      return
    end

    @new_things = [ ]
    how_recent = 6.months.ago

    @the_person = Person.find(params[:id])

    if @person
      @new_things +=
        @person.node_versions.select { |node_version| node_version.created_at >= how_recent }.map{ |node_version| node_version.new_thing } 
      @new_things +=
        @person.postings.select { |person| person.created_at >= how_recent }.map{ |person| person.new_thing } 
      @new_things +=
        @person.tagged_nodes.select { |tagged_node| tagged_node.created_at >= how_recent }.map{ |tagged_node| tagged_node.new_thing } 
    end

    respond_to do |format|
      format.html { @new_things }
      format.atom { @new_things }
    end
  end

  def models
    @the_person = Person.find(params[:id])
  end

end
