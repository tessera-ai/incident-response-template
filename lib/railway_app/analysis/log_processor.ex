defmodule RailwayApp.Analysis.LogProcessor do
  @moduledoc """
  Processes incoming log events, detects patterns, and triggers incident detection.
  Maintains a sliding window of recent logs per service.
  """

  use GenServer

  alias RailwayApp.Analysis.LLMRouter

  require Logger

  @window_size 20
  @batch_interval 5_000
  @critical_patterns [
    ~r/error|exception|fatal|crash/i,
    ~r/out of memory|oom/i,
    ~r/connection refused|econnrefused/i,
    ~r/timeout|timed out/i,
    ~r/500|502|503|504/i
  ]

  defmodule State do
    @moduledoc false
    defstruct log_windows: %{},
              pending_analysis: %{},
              batch_timer: nil
  end

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def process_log(log_event) do
    GenServer.cast(__MODULE__, {:process_log, log_event})
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    # Subscribe to log events from WebSocket client
    Phoenix.PubSub.subscribe(RailwayApp.PubSub, "railway:logs")

    state = %State{
      log_windows: %{},
      pending_analysis: %{},
      batch_timer: schedule_batch_analysis()
    }

    {:ok, state}
  end

  @impl true
  def handle_cast({:process_log, log_event}, state) do
    service_id = log_event[:service_id] || "unknown"

    # Add log to service window
    window = Map.get(state.log_windows, service_id, [])
    new_window = [log_event | window] |> Enum.take(@window_size)

    # Check for critical patterns
    is_critical = detect_critical_pattern(log_event)

    new_state =
      if is_critical do
        # Mark for immediate analysis
        pending =
          Map.update(state.pending_analysis, service_id, [log_event], fn logs ->
            [log_event | logs]
          end)

        %{
          state
          | log_windows: Map.put(state.log_windows, service_id, new_window),
            pending_analysis: pending
        }
      else
        %{state | log_windows: Map.put(state.log_windows, service_id, new_window)}
      end

    {:noreply, new_state}
  end

  @impl true
  def handle_info({:log_event, log_event}, state) do
    handle_cast({:process_log, log_event}, state)
  end

  @impl true
  def handle_info(:analyze_batch, state) do
    # Analyze all services with pending logs
    new_state =
      state.pending_analysis
      |> Enum.reduce(state, fn {service_id, logs}, acc_state ->
        analyze_service_logs(service_id, logs, acc_state)
      end)

    # Clear pending analysis and reschedule
    new_state = %{new_state | pending_analysis: %{}, batch_timer: schedule_batch_analysis()}

    {:noreply, new_state}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("Unhandled message in LogProcessor: #{inspect(msg)}")
    {:noreply, state}
  end

  # Private Functions

  defp detect_critical_pattern(log_event) do
    message = log_event[:message] || ""
    level = log_event[:level] || "info"

    level_critical = level in ["error", "fatal", "critical"]

    pattern_match =
      Enum.any?(@critical_patterns, fn pattern ->
        String.match?(message, pattern)
      end)

    level_critical || pattern_match
  end

  defp analyze_service_logs(service_id, logs, state) do
    Logger.info("Analyzing #{length(logs)} logs for service #{service_id}")

    # Get service config
    service_config = get_or_create_service_config(service_id)

    # Get full log window for context
    window = Map.get(state.log_windows, service_id, logs)

    if test_env?() do
      # In tests, run synchronously and rely on pattern-based detection to avoid
      # external LLM calls and background tasks.
      create_pattern_incident(service_id, service_config, window)
      state
    else
      # Analyze with LLM in background
      Task.Supervisor.start_child(RailwayApp.TaskSupervisor, fn ->
        case LLMRouter.analyze_logs(window, service_config.service_name) do
          {:ok, analysis} ->
            # Create incident if confidence threshold is met
            if analysis.confidence >= service_config.confidence_threshold do
              create_incident(service_id, service_config, analysis, window)
            else
              Logger.info(
                "Incident confidence (#{analysis.confidence}) below threshold (#{service_config.confidence_threshold}), skipping"
              )
            end

          {:error, reason} ->
            Logger.warning("LLM analysis failed: #{inspect(reason)}", %{})
            # Fall back to pattern-based detection
            create_pattern_incident(service_id, service_config, logs)
        end
      end)

      state
    end
  end

  defp create_incident(service_id, service_config, analysis, logs) do
    # Create signature for deduplication
    signature = generate_signature(service_id, analysis.root_cause)

    # Get environment_id from the first log event or from config
    environment_id =
      logs
      |> List.first()
      |> case do
        %{environment_id: env_id} when is_binary(env_id) ->
          env_id

        _ ->
          # Use first monitored environment as default
          "RAILWAY_MONITORED_ENVIRONMENTS"
          |> System.get_env("")
          |> String.split(",")
          |> List.first()
          |> String.trim()
      end

    attrs = %{
      service_id: service_id,
      service_name: service_config.service_name,
      environment_id: environment_id,
      signature: signature,
      severity: analysis.severity,
      status: "detected",
      confidence: analysis.confidence,
      root_cause: analysis.root_cause,
      recommended_action: analysis.recommended_action,
      reasoning: analysis.reasoning,
      log_context: %{logs: logs |> Enum.take(20)},
      detected_at: DateTime.utc_now(),
      service_config_id: service_config_id_for_env(service_config)
    }

    case RailwayApp.Incidents.create_or_update_incident(attrs) do
      {:ok, incident, :created} ->
        Logger.info("Created NEW incident #{incident.id} for service #{service_id}")

        # Only broadcast for NEW incidents to trigger Slack and auto-remediation
        Phoenix.PubSub.broadcast(
          RailwayApp.PubSub,
          "incidents:new",
          {:incident_detected, incident}
        )

        {:ok, incident}

      {:ok, incident, :updated} ->
        Logger.info(
          "Updated existing incident #{incident.id} for service #{service_id} (no notification)"
        )

        {:ok, incident}

      {:ok, incident, :skipped} ->
        Logger.info("Skipped already resolved incident #{incident.id} for service #{service_id}")
        {:ok, incident}

      {:error, changeset} ->
        Logger.error("Failed to create incident: #{inspect(changeset.errors)}")
        {:error, changeset}
    end
  end

  defp create_pattern_incident(service_id, service_config, logs) do
    # Simple pattern-based incident creation when LLM is unavailable
    first_error =
      Enum.find(logs, fn log -> log[:level] in ["error", "fatal"] end) || List.first(logs)

    attrs = %{
      service_id: service_id,
      service_name: service_config.service_name,
      signature: generate_signature(service_id, first_error[:message] || "unknown"),
      severity: "high",
      status: "detected",
      confidence: 0.5,
      root_cause: "Pattern-based detection: #{first_error[:message]}",
      recommended_action: "manual_fix",
      reasoning: "Detected via error pattern matching (LLM unavailable)",
      log_context: %{logs: logs |> Enum.take(20)},
      detected_at: DateTime.utc_now(),
      service_config_id: service_config_id_for_env(service_config)
    }

    case RailwayApp.Incidents.create_or_update_incident(attrs) do
      {:ok, incident, :created} ->
        Logger.info("Created NEW pattern incident #{incident.id}")

        Phoenix.PubSub.broadcast(
          RailwayApp.PubSub,
          "incidents:new",
          {:incident_detected, incident}
        )

        {:ok, incident}

      {:ok, incident, :updated} ->
        Logger.info("Updated existing pattern incident #{incident.id} (no notification)")
        {:ok, incident}

      {:ok, incident, :skipped} ->
        Logger.info("Skipped already resolved pattern incident #{incident.id}")
        {:ok, incident}

      {:error, changeset} ->
        Logger.error("Failed to create pattern incident: #{inspect(changeset.errors)}")
        {:error, changeset}
    end
  end

  defp generate_signature(service_id, message) do
    # Generate a stable signature for deduplication
    normalized = String.downcase(message) |> String.slice(0, 100)

    :crypto.hash(:sha256, "#{service_id}:#{normalized}")
    |> Base.encode16()
    |> String.slice(0, 16)
  end

  defp get_or_create_service_config(service_id) do
    case RailwayApp.ServiceConfigs.get_by_service_id(service_id) do
      nil ->
        # Create default config
        {:ok, config} =
          RailwayApp.ServiceConfigs.create_service_config(%{
            service_id: service_id,
            service_name: "Service #{service_id}",
            auto_remediation_enabled: true,
            confidence_threshold: 0.7
          })

        config

      config ->
        config
    end
  end

  defp service_config_id_for_env(service_config) do
    if test_env?(), do: nil, else: service_config.id
  end

  @compile_env Mix.env()
  defp test_env? do
    @compile_env == :test
  end

  defp schedule_batch_analysis do
    Process.send_after(self(), :analyze_batch, @batch_interval)
  end
end
