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
    plug(TabletopWeb.Plugs.SecurityHeaders)
    plug(TabletopWeb.Plugs.AnonymousId)
    # Attaches request metadata (path, params, headers) to any error captured
    # during this request. Note there is deliberately no `Sentry.PlugCapture` in
    # the endpoint: that is for Cowboy, and on Bandit it produces duplicate
    # events — PlugContext alone is the documented Bandit setup.
    plug(Sentry.PlugContext)
    plug(:fetch_current_scope_for_user)
  end

  pipeline :api do
    plug(:accepts, ["json"])
  end

  scope "/", TabletopWeb do
    pipe_through(:browser)

    get("/about", PageController, :about)
    get("/privacy", PageController, :privacy)
    get("/terms", PageController, :terms)
    get("/code-of-conduct", PageController, :code_of_conduct)
    get("/health", PageController, :health)

    # `Sentry.LiveViewHook` is on every live_session because almost all of this
    # app's behaviour lives in LiveView callbacks rather than controllers —
    # without it a captured error carries no request URL, user agent or
    # breadcrumbs, which is most of what makes an issue diagnosable.
    live_session :phone_camera, on_mount: [Sentry.LiveViewHook] do
      live "/phone-camera/:token", PhoneCameraLive, :index
    end
  end

  # Other scopes may use custom stacks.
  # scope "/api", TabletopWeb do
  #   pipe_through :api
  # end

  import Phoenix.LiveDashboard.Router

  # The LiveDashboard is mounted in *every* environment, at the same path. In
  # development it is open, like the rest of `/dev`; everywhere else it is
  # restricted to the user ids in the `LIVE_DASHBOARD_USER_IDS` env var (see
  # `Tabletop.Accounts.Scope.live_dashboard?/1`), which defaults to empty — so
  # the route exists in production but admits nobody until it is configured.
  #
  # The guard is applied as a pipeline *and* an `on_mount` list because the two
  # cover different halves of the route set — see the docs on
  # `TabletopWeb.UserAuth.require_live_dashboard_access/2`.
  #
  # Both are selected at compile time rather than mounting `live_dashboard/2`
  # twice: a second mount would collide on the `:live_dashboard` live_session
  # name, and the dashboard resolves all of its internal links against a single
  # `@live_dashboard_prefix` recorded by whichever mount compiled first, so the
  # loser's navigation would point into the wrong prefix.
  @dashboard_pipeline if Application.compile_env(:tabletop, :dev_routes),
                        do: [:browser],
                        else: [
                          :browser,
                          :require_authenticated_user,
                          :require_live_dashboard_access
                        ]

  @dashboard_on_mount if Application.compile_env(:tabletop, :dev_routes),
                        do: [],
                        else: [
                          {TabletopWeb.UserAuth, :require_authenticated},
                          {TabletopWeb.UserAuth, :require_live_dashboard}
                        ]

  scope "/dev" do
    pipe_through(@dashboard_pipeline)

    # `csp_nonce_assign_key` must be set: the dashboard layout renders an
    # inline `<script>` defining `window.LiveDashboard` (its own JS bundle
    # then reads `window.LiveDashboard.customHooks` on load). Our CSP has no
    # `'unsafe-inline'` in `script-src`, so without a nonce the browser blocks
    # that script and the dashboard's JS throws before the socket connects —
    # the page renders dead and never updates. `:csp_nonce` is the per-request
    # assign set by `TabletopWeb.Plugs.SecurityHeaders`.
    # `ecto_repos` is named explicitly rather than left to the dashboard's
    # auto-discovery (an `Ecto.Repo.all_running/0` RPC per mount) — we have
    # exactly one repo and it is known at compile time. The "Ecto Stats" page
    # itself is powered by the optional `:ecto_psql_extras` dep; drop that and
    # the page degrades to install instructions.
    live_dashboard("/dashboard",
      metrics: TabletopWeb.Telemetry,
      csp_nonce_assign_key: :csp_nonce,
      ecto_repos: [Tabletop.Repo],
      on_mount: @dashboard_on_mount
    )
  end

  # Swoosh mailbox preview stays development-only — it exposes every sent email.
  if Application.compile_env(:tabletop, :dev_routes) do
    scope "/dev" do
      pipe_through(:browser)

      forward("/mailbox", Plug.Swoosh.MailboxPreview)
    end
  end

  ## Authentication routes

  scope "/", TabletopWeb do
    pipe_through([:browser, :require_authenticated_user])

    live_session :require_authenticated_user,
      on_mount: [
        Sentry.LiveViewHook,
        {TabletopWeb.UserAuth, :require_authenticated},
        {TabletopWeb.UserNotifications, :default}
      ] do
      live("/users/settings", UserLive.Settings, :edit)
    end

    post("/users/update-password", UserSessionController, :update_password)
  end

  # require user to be recently athenticated (sudo mode) to access these routes
  scope "/", TabletopWeb do
    pipe_through([:browser, :require_authenticated_user])

    live_session :require_authenticated_user_and_sudo_mode,
      on_mount: [
        Sentry.LiveViewHook,
        {TabletopWeb.UserAuth, :require_authenticated}
      ] do
      live("/users/settings/confirm-password", UserLive.Settings, :confirm_password)
    end
  end

  scope "/", TabletopWeb do
    pipe_through([:browser])

    live_session :tournaments_admin,
      on_mount: [
        Sentry.LiveViewHook,
        {TabletopWeb.UserAuth, :require_admin},
        {TabletopWeb.UserNotifications, :default}
      ] do
      live "/tournaments/new", TournamentLive.Form, :new
      live "/tournaments/:id/edit", TournamentLive.Form, :edit
      live "/tournaments/:id/admin", TournamentLive.Admin, :admin
    end

    live_session :current_user,
      on_mount: [
        Sentry.LiveViewHook,
        {TabletopWeb.UserAuth, :mount_current_scope},
        {TabletopWeb.UserNotifications, :default}
      ] do
      live("/users/register", UserLive.Registration, :new)
      live("/users/log-in", UserLive.Login, :new)
      live("/users/confirmation-pending", UserLive.ConfirmationPending, :new)
      live("/users/reset-password", UserLive.ForgotPassword, :new)
      live("/users/reset-password/:token", UserLive.ResetPassword, :edit)

      live "/", GameLive.Index, :index
      live "/games/:id", GameLive.Show, :show
      live "/games/:id/edit", GameLive.Form, :edit
      live "/games/:id/pre-join", GameLive.PreJoin, :pre_join
      live "/camera-setup", CameraSetupLive, :index

      live "/tournaments", TournamentLive.Index, :index
      live "/tournaments/:id", TournamentLive.Show, :show
    end

    get("/users/confirm/:token", UserSessionController, :confirm)
    post("/users/log-in", UserSessionController, :create)
    delete("/users/log-out", UserSessionController, :delete)
  end
end
