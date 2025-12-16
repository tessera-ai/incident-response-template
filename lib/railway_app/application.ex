defmodule RailwayApp.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    # Validate required environment variables first
    validate_environment!()

    env = Application.get_env(:railway_app, :env, :dev)

    # Wait for database readiness in all environments (required for this app)
    Logger.info("Checking database readiness...")

    case RailwayApp.Startup.HealthChecker.wait_for_database_ready() do
      :ok ->
        Logger.info("Database ready, proceeding with application startup")

      {:error, reason} ->
        Logger.error("Database readiness check failed: #{inspect(reason)}")
        raise "Database is not ready for application startup: #{inspect(reason)}"
    end

    children = base_children() ++ database_children() ++ runtime_children(env)

    opts = [strategy: :one_for_one, name: RailwayApp.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp runtime_children(env) do
    common_runtime = [
      # Dynamic supervisor for Railway WebSocket connections
      RailwayApp.Railway.WebSocketSupervisor,
      # Connection manager for orchestrating service connections
      {RailwayApp.Railway.ConnectionManager,
       project_id: System.get_env("RAILWAY_PROJECT_ID") || "local_dev"},
      # Telemetry collector for metrics
      RailwayApp.Railway.TelemetryCollector,
      # Log processor for incident detection
      RailwayApp.Analysis.LogProcessor,
      # Pipeline for incident broadcasting and notifications
      RailwayApp.Analysis.Pipeline,
      # Remediation coordinator for auto-fix actions
      RailwayApp.Remediation.Coordinator,
      # Conversation manager for Slack interactions
      RailwayApp.Conversations.ConversationManager,
      # Retention cleanup worker (runs daily)
      RailwayApp.Retention.CleanupWorker
    ]

    case env do
      :test ->
        # In tests, include all runtime children
        common_runtime

      _ ->
        # In dev and prod, include all runtime children
        common_runtime
    end
  end

  defp base_children do
    [
      RailwayAppWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:railway_app, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: RailwayApp.PubSub},
      # Registry for naming WebSocket connections
      {Registry, keys: :unique, name: RailwayApp.Registry},
      # Task supervisor for concurrent operations
      {Task.Supervisor, name: RailwayApp.TaskSupervisor},
      # Start to serve requests, typically the last entry
      RailwayAppWeb.Endpoint
    ]
  end

  defp database_children do
    [
      RailwayApp.Repo
    ]
  end

  defp validate_environment! do
    env = Application.get_env(:railway_app, :env, :dev)

    # In production, validate critical environment variables
    if env == :prod do
      database_url = System.get_env("DATABASE_URL")
      secret_key_base = System.get_env("SECRET_KEY_BASE")
      railway_api_token = System.get_env("RAILWAY_API_TOKEN")

      # Database URL is always required
      if !database_url do
        raise "DATABASE_URL environment variable is required in production"
      end

      # Secret key base is always required
      if !secret_key_base do
        raise "SECRET_KEY_BASE environment variable is required in production"
      end

      # Railway API token is required for log streaming
      if !railway_api_token do
        raise "RAILWAY_API_TOKEN environment variable is required in production"
      end

      # They represent where THIS app is deployed, but monitoring external services
      # External services are configured via RAILWAY_MONITORED_PROJECTS and RAILWAY_MONITORED_ENVIRONMENTS

      if !System.get_env("RAILWAY_MONITORED_PROJECTS") and
           !System.get_env("RAILWAY_MONITORED_ENVIRONMENTS") do
        Logger.warning(
          "No external services configured via RAILWAY_MONITORED_PROJECTS or RAILWAY_MONITORED_ENVIRONMENTS",
          %{}
        )

        Logger.info("To monitor external Railway services, set:")
        Logger.info("  RAILWAY_MONITORED_PROJECTS=project1,project2,project3")
        Logger.info("  RAILWAY_MONITORED_ENVIRONMENTS=production,staging,development")
      end

      # Slack integration is required (all must be non-empty)
      slack_token = System.get_env("SLACK_BOT_TOKEN")
      slack_secret = System.get_env("SLACK_SIGNING_SECRET")
      slack_channel = System.get_env("SLACK_CHANNEL_ID")

      if !present?(slack_token) or !present?(slack_secret) or !present?(slack_channel) do
        raise "Slack environment variables are required in production: SLACK_BOT_TOKEN, SLACK_SIGNING_SECRET, SLACK_CHANNEL_ID"
      end

      # Log warning for missing LLM provider (but don't fail startup)
      if !System.get_env("OPENAI_API_KEY") do
        Logger.warning("No LLM provider configured. AI features will be disabled.", %{})
      end
    end
  end

  defp present?(value) do
    is_binary(value) and String.trim(value) != ""
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    RailwayAppWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
