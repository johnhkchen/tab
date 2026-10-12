defmodule TabWeb.Router do
  use TabWeb, :router

  import TabWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {TabWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", TabWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  scope "/", TabWeb do
    pipe_through :api

    get "/healthz", HealthController, :show
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:tab, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: TabWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
      # Every page at 360 px, signed in as a demo person (`mise run check:narrow`).
      get "/narrow", TabWeb.Dev.NarrowController, :show
    end
  end

  ## Authentication routes

  scope "/", TabWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :require_authenticated_user,
      on_mount: [{TabWeb.UserAuth, :require_authenticated}] do
      live "/users/settings", UserLive.Settings, :edit
      live "/users/settings/confirm-email/:token", UserLive.Settings, :confirm_email

      live "/welcome", WelcomeLive, :show
      live "/profile", ProfileLive, :edit
      live "/join/:token", JoinLive, :show

      live "/groups", GroupLive.Index, :index
      live "/groups/:group_id", GroupLive.Show, :show
      live "/groups/:group_id/members", GroupLive.Members, :show
      live "/groups/:group_id/settle", GroupLive.Settle, :show
      live "/groups/:group_id/bills", GroupLive.Bills, :show
      live "/groups/:group_id/temporary", GroupLive.Temporary, :show
      live "/groups/:group_id/remind/:party", GroupLive.Remind, :show
      live "/groups/:group_id/expenses/new", ExpenseLive.Form, :new
      live "/groups/:group_id/expenses/:id", ExpenseLive.Show, :show
      live "/groups/:group_id/expenses/:id/edit", ExpenseLive.Form, :edit
    end

    post "/users/update-password", UserSessionController, :update_password
    get "/export.csv", ExportController, :show
  end

  scope "/", TabWeb do
    pipe_through [:browser]

    live_session :current_user,
      on_mount: [{TabWeb.UserAuth, :mount_current_scope}] do
      live "/users/log-in", UserLive.Login, :new
      live "/users/log-in/:token", UserLive.Confirmation, :new
    end

    # A statement link: no sign-in, the token decides (Tab.Statements).
    get "/s/:token", StatementController, :show

    post "/users/log-in", UserSessionController, :create
    delete "/users/log-out", UserSessionController, :delete
  end
end
