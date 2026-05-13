defmodule TabletopWeb.Router do
  use TabletopWeb, :router

  import TabletopWeb.UserAuth

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {TabletopWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
    plug(:fetch_current_scope_for_user)
  end

  pipeline :api do
    plug(:accepts, ["json"])
  end

  scope "/", TabletopWeb do
    pipe_through(:browser)

    # get("/", PageController, :home)
    get("/about", PageController, :about)

    live_session :phone_camera do
      live "/phone-camera/:token", PhoneCameraLive, :index
    end
  end

  # Other scopes may use custom stacks.
  # scope "/api", TabletopWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:tabletop, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through(:browser)

      live_dashboard("/dashboard", metrics: TabletopWeb.Telemetry)
      forward("/mailbox", Plug.Swoosh.MailboxPreview)
    end
  end

  ## Authentication routes

  scope "/", TabletopWeb do
    pipe_through([:browser, :require_authenticated_user])

    live_session :require_authenticated_user,
      on_mount: [{TabletopWeb.UserAuth, :require_authenticated}] do
      live("/users/settings", UserLive.Settings, :edit)
    end

    post("/users/update-password", UserSessionController, :update_password)
  end

  # require user to be recently athenticated (sudo mode) to access these routes
  scope "/", TabletopWeb do
    pipe_through([:browser, :require_authenticated_user])

    live_session :require_authenticated_user_and_sudo_mode,
      on_mount: [
        {TabletopWeb.UserAuth, :require_authenticated}
      ] do
      live("/users/settings/confirm-password", UserLive.Settings, :confirm_password)
    end
  end

  scope "/", TabletopWeb do
    pipe_through([:browser])

    live_session :current_user,
      on_mount: [{TabletopWeb.UserAuth, :mount_current_scope}] do
      live("/users/register", UserLive.Registration, :new)
      live("/users/log-in", UserLive.Login, :new)
      live("/users/confirmation-pending", UserLive.ConfirmationPending, :new)

      live "/", GameLive.Index, :index
      live "/games/:id", GameLive.Show, :show
      live "/games/:id/edit", GameLive.Form, :edit
      live "/games/:id/pre-join", GameLive.PreJoin, :pre_join
      live "/camera-setup", CameraSetupLive, :index
    end

    get("/users/confirm/:token", UserSessionController, :confirm)
    post("/users/log-in", UserSessionController, :create)
    delete("/users/log-out", UserSessionController, :delete)
  end
end
