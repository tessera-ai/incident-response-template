defmodule RailwayApp.Startup.HealthChecker do
  @moduledoc """
  Simple health checker that can be used to verify application readiness.

  This is a utility module, not a GenServer, to avoid supervisor tree issues.
  """

  require Logger

  @max_attempts 60
  @retry_interval 1_000

  @doc """
  Wait for database to be ready with migrations completed
  """
  def wait_for_database_ready(opts \\ []) do
    max_attempts = Keyword.get(opts, :max_attempts, @max_attempts)
    retry_interval = Keyword.get(opts, :retry_interval, @retry_interval)

    Logger.info("Checking database readiness...")

    with :ok <- wait_for_connection(max_attempts, retry_interval),
         :ok <- wait_for_migrations(max_attempts, retry_interval),
         :ok <- verify_critical_tables() do
      Logger.info("Database is ready")
      :ok
    else
      {:error, reason} ->
        Logger.error("Database readiness check failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp wait_for_connection(0, _interval), do: {:error, :database_connection_timeout}

  defp wait_for_connection(attempts, interval) do
    case Ecto.Adapters.SQL.query(RailwayApp.Repo, "SELECT 1", []) do
      {:ok, _} ->
        Logger.info("Database connection established")
        :ok

      {:error, reason} ->
        if attempts > 1 do
          Logger.debug("Database not ready, retrying... (#{attempts - 1} attempts left)")
          :timer.sleep(interval)
          wait_for_connection(attempts - 1, interval)
        else
          {:error, {:database_connection_failed, reason}}
        end
    end
  end

  defp wait_for_migrations(0, _interval), do: {:error, :migration_timeout}

  defp wait_for_migrations(attempts, interval) do
    case Ecto.Adapters.SQL.query(RailwayApp.Repo, "SELECT COUNT(*) FROM schema_migrations", []) do
      {:ok, %{rows: [[count]]}} when count > 0 ->
        Logger.info("Migrations completed (#{count} records)")
        :ok

      {:error, %Postgrex.Error{postgres: %{code: :undefined_table}}} ->
        if attempts > 1 do
          Logger.debug("Waiting for migrations... (#{attempts - 1} attempts left)")
          :timer.sleep(interval)
          wait_for_migrations(attempts - 1, interval)
        else
          {:error, :migration_timeout}
        end

      {:error, reason} ->
        {:error, {:migration_check_failed, reason}}
    end
  end

  defp verify_critical_tables do
    critical_tables = ["service_configurations", "incidents", "service_configs"]

    Enum.each(critical_tables, fn table ->
      case Ecto.Adapters.SQL.query(
             RailwayApp.Repo,
             "SELECT EXISTS (SELECT FROM information_schema.tables WHERE table_schema = 'public' AND table_name = $1)",
             [table]
           ) do
        {:ok, %{rows: [[true]]}} ->
          Logger.debug("Table #{table} exists")

        {:ok, %{rows: [[false]]}} ->
          Logger.error("Critical table #{table} does not exist")
          {:error, {:critical_table_missing, table}}

        {:error, reason} ->
          {:error, {:table_check_failed, table, reason}}
      end
    end)

    :ok
  end
end
