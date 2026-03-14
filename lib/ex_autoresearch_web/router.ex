defmodule ExAutoresearchWeb.Router do
  use ExAutoresearchWeb, :router

  import Oban.Web.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ExAutoresearchWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", ExAutoresearchWeb do
    pipe_through :browser

    live "/", DashboardLive
    get "/export/:tag", ExportController, :campaign
  end

  # Other scopes may use custom stacks.
  # scope "/api", ExAutoresearchWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:ex_autoresearch, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: ExAutoresearchWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end

    scope "/" do
      pipe_through :browser

      oban_dashboard("/oban")
    end
  end

  # AshAdmin disabled — conflicts with jido's gettext requirement
  # if Application.compile_env(:ex_autoresearch, :dev_routes) do
  #   import AshAdmin.Router
  #   scope "/admin" do
  #     pipe_through :browser
  #     ash_admin "/"
  #   end
  # end
end
