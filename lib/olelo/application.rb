module Olelo
  # Main class of the application
  class Application
    include Util
    include Hooks
    include ErrorHandler
    include Routing
    include ApplicationHelper

    patterns :path => Page::PATH_PATTERN
    attr_reader :page
    attr_setter :on_error

    has_around_hooks :request, :routing, :action, :title, :footer, :login_buttons, :edit_buttons
    has_hooks :auto_login, :render, :menu, :head, :script

    class<< self
      attr_accessor :reserved_paths
      def reserved_path?(path)
        path = '/' + path.cleanpath
        reserved_paths.any? {|pattern| path =~ pattern }
      end
    end

    def initialize(app = nil)
      @app = app
    end

    # Executed before each request
    before :routing do
      Olelo.logger.debug env

      User.current = User.find(session[:olelo_user])
      if !User.current
        invoke_hook(:auto_login)
        User.current ||= User.anonymous(request)
      end

      response['Content-Type'] = 'application/xhtml+xml;charset=utf-8'
    end

    # Executed after each request
    after :routing do
      if User.logged_in?
        session[:olelo_user] = User.current.name
      else
        session.delete(:olelo_user)
      end
      User.current = nil
    end

    hook :menu do |menu|
      if menu.name == :actions && page && !page.new?
        menu.item(:view, :href => build_path(page.path), :accesskey => 'v')
        edit_menu = menu.item(:edit, :href => build_path(page, :action => :edit), :accesskey => 'e')
        edit_menu.item(:new, :href => build_path(page, :action => :new), :accesskey => 'n')
        if !page.root?
          edit_menu.item(:move, :href => build_path(page, :action => :move))
          edit_menu.item(:delete, :href => build_path(page, :action => :delete))
        end
        history_menu = menu.item(:history, :href => build_path(page, :action => :history), :accesskey => 'h')

        if @menu_versions
          head = !page.head? && (Olelo::Page.find(page.path) rescue nil)
          if page.previous_version || head || page.next_version
            history_menu.item(:older, :href => build_path(page, original_params.merge(:version => page.previous_version)),
                              :accesskey => 'o') if page.previous_version
            history_menu.item(:head, :href => build_path(page.path, original_params), :accesskey => 'c') if head
            history_menu.item(:newer, :href => build_path(page, original_params.merge(:version => page.next_version)),
                              :accesskey => 'n') if page.next_version
          end
        end
      end
    end

    # Handle 404s
    error NotFound do |error|
      Olelo.logger.debug(error)
      cache_control :no_cache => true
      halt render(:not_found, :locals => {:error => error})
    end

    error StandardError do |error|
      if on_error
        Olelo.logger.error error
        (error.try(:messages) || [error.message]).each {|msg| flash.error!(msg) }
        halt render(on_error)
      end
    end

    # Show wiki error page
    error Exception do |error|
      Olelo.logger.error(error)
      cache_control :no_cache => true
      halt render(:error, :locals => {:error => error})
    end

    get '/login' do
      render :login
    end

    post '/login' do
      on_error :login
      User.current = User.authenticate(params[:user], params[:password])
      redirect build_path(session.delete(:olelo_goto))
    end

    post '/signup' do
      on_error :login
      raise 'Sign-up is disabled' if !Config['authentication.enable_signup']
      User.current = User.create(params[:user], params[:password],
                                 params[:confirm], params[:email])
      redirect build_path('/')
    end

    get '/logout' do
      User.current = User.anonymous(request)
      redirect build_path('/')
    end

    get '/profile' do
      raise 'Anonymous users do not have a profile.' if !User.logged_in?
      render :profile
    end

    post '/profile' do
      raise 'Anonymous users do not have a profile.' if !User.logged_in?
      on_error :profile
      User.current.modify do |u|
        u.change_password(params[:oldpassword], params[:password], params[:confirm]) if !params[:password].blank?
        u.email = params[:email]
      end
      flash.info! :changes_saved.t
      render :profile
    end

    get '/changes/:version(/:path)' do
      @page = Page.find!(params[:path])
      @diff = page.diff(nil, params[:version])
      @version = @diff.to
      cache_control :version => @version
      render :changes
    end

    get '/history(/:path)' do
      @page = Page.find!(params[:path])
      @per_page = 30
      @page_nr = [params[:page].to_i, 1].max
      @history = page.history((@page_nr - 1) * @per_page)
      @page_count = @page_nr + @history.length / @per_page
      @history = @history[0...@per_page]
      cache_control :version => page.version
      render :history
    end

    get '/move/:path' do
      @page = Page.find!(params[:path])
      render :move
    end

    get '/delete/:path' do
      @page = Page.find!(params[:path])
      render :delete
    end

    post '/move/:path' do
      Page.transaction do
        @page = Page.find!(params[:path])
        on_error :move
        destination = params[:destination].cleanpath
        raise :reserved_path.t if self.class.reserved_path?(destination)
        page.move(destination)
        Page.commit(:page_moved.t(:page => page.path, :destination => destination))
        redirect build_path(page.path)
      end
    end

    get '/compare/:versions(/:path)', :versions => '(?:\w+)\.{2,3}(?:\w+)' do
      @page = Page.find!(params[:path])
      versions = params[:versions].split(/\.{2,3}/)
      @diff = page.diff(versions.first, versions.last)
      render :compare
    end

    get '/compare(/:path)' do
      versions = params[:versions] || []
      redirect build_path(params[:path], :action => versions.size < 2 ? :history : "compare/#{versions.first}...#{versions.last}")
    end

    get '/edit(/:path)' do
      @page = Page.find!(params[:path])
      render :edit
    end

    get '/new(/:path)' do
      @page = Page.new(params[:path])
      flash.error! :reserved_path.t if self.class.reserved_path?(page.path)
      params[:path] = !page.root? && Page.find(page.path) ? page.path + '/' : page.path
      render :edit
    end

    def post_edit
      raise 'No content' if !params[:content]
      params[:content].gsub!("\r\n", "\n")
      message = :page_edited.t(:page => page.title)
      message << " - #{params[:comment]}" if !params[:comment].blank?

      page.content = if params[:pos]
                       [page.content[0, params[:pos].to_i].to_s,
                        params[:content],
                        page.content[params[:pos].to_i + params[:len].to_i .. -1]].join
                     else
                       params[:content]
                     end
      redirect build_path(page.path) if @close && !page.modified?
      check do |errors|
        errors << :version_conflict.t if !page.new? && page.version.to_s != params[:version]
        errors << :no_changes.t if !page.modified?
      end
      page.save

      Page.commit(message)
      params.delete(:comment)
    end

    def post_upload
      raise 'No file' if !params[:file]
      raise :version_conflict.t if !page.new? && page.version.to_s != params[:version]
      page.content = params[:file][:tempfile]
      page.save
      Page.commit(:page_uploaded.t(:page => page.title))
    end

    def post_attributes
      page.update_attributes(params)
      redirect build_path(page.path) if @close && !page.modified?
      check do |errors|
        errors << :version_conflict.t if !page.new? && page.version.to_s != params[:version]
        errors << :no_changes.t if !page.modified?
      end
      page.save
      Page.commit(:attributes_edited.t(:page => page.title))
    end

    def show_page
      @menu_versions = true
      halt render(:show, :locals => {:content => page.try(:content)})
    end

    get '/version/:version(/:path)|/(:path)', :tail => true do
      begin
        @page = Page.find!(params[:path], params[:version])
        cache_control :version => page.version
        show_page
      rescue NotFound
        redirect build_path(params[:path], :action => :new) if params[:version].blank?
        raise
      end
    end

    post '/(:path)', :tail => true do
      action, @close = params[:action].to_s.split('-')
      if respond_to? "post_#{action}"
        on_error :edit
        Page.transaction do
          @page = Page.find(params[:path]) || Page.new(params[:path])
          raise :reserved_path.t if self.class.reserved_path?(page.path)
          send("post_#{action}")
        end
      else
        raise 'Invalid action'
      end

      if @close
        flash.clear
        redirect build_path(page.path)
      else
        flash.info! :changes_saved.t
        render :edit
      end
    end

    delete '/:path', :tail => true do
      Page.transaction do
        @page = Page.find!(params[:path])
          on_error :delete
        page.delete
        Page.commit(:page_deleted.t(:page => page.path))
        render :deleted
      end
    end
  end
end
