defmodule RailwayAppWeb.Router do
  use RailwayAppWeb, :router
  use PhoenixSwagger

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {RailwayAppWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", RailwayAppWeb do
    pipe_through :browser

    # Dashboard is the home page
    live "/", DashboardLive, :index

    # Railway logs LiveView routes
    live "/railway/logs/:project_id/:service_id", RailwayLogsLive, :index
    live "/railway/logs/:project_id/:service_id/settings", RailwayLogsLive, :settings
  end

  # Health check endpoint (no auth required for Railway)
  scope "/", RailwayAppWeb do
    pipe_through :api

    get "/health", HealthController, :index
  end

  # API endpoints for Slack webhooks
  scope "/api", RailwayAppWeb do
    pipe_through :api

    post "/slack/interactive", SlackWebhookController, :interactive
    post "/slack/slash", SlackWebhookController, :slash
    post "/slack/events", SlackWebhookController, :events
  end

  # Generate swagger JSON
  get "/api/swagger.json", RailwayAppWeb.SwaggerController, :spec

  # Swagger UI
  get "/api/swagger", RailwayAppWeb.SwaggerController, :ui

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:railway_app, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: RailwayAppWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  # Generate Swagger JSON spec
  def swagger_info do
    %{
      info: %{
        version: "0.1.0",
        title: "Railway App API",
        description: "API for Railway App monitoring and incident management"
      },
      host: "${{RAILWAY_PUBLIC_DOMAIN}}",
      basePath: "/",
      schemes: ["http", "https"],
      consumes: ["application/json", "application/x-www-form-urlencoded"],
      produces: ["application/json"],
      definitions: %{
        HealthResponse: %{
          type: "object",
          properties: %{
            status: %{type: "string", enum: ["ok", "degraded", "error"]},
            components: %{
              type: "object",
              properties: %{
                app: %{type: "string", enum: ["ok", "degraded", "error"]},
                database: %{type: "string", enum: ["ok", "degraded", "error"]},
                log_stream: %{type: "string", enum: ["ok", "degraded", "error"]}
              }
            }
          },
          example: %{
            status: "ok",
            components: %{
              app: "ok",
              database: "ok",
              log_stream: "ok"
            }
          }
        },
        SlackResponse: %{
          type: "object",
          properties: %{
            response_type: %{type: "string", enum: ["ephemeral", "in_channel"]},
            text: %{type: "string"}
          },
          example: %{
            response_type: "ephemeral",
            text: "Processing your request..."
          }
        },
        ErrorResponse: %{
          type: "object",
          properties: %{
            error: %{type: "string"}
          },
          example: %{
            error: "Invalid payload"
          }
        }
      }
    }
  end
end
