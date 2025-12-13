defmodule RailwayApp.Railway.WebSocketClient do
  @moduledoc """
  WebSocket client for streaming Railway logs via GraphQL subscriptions.
  Maintains persistent connection with reconnection logic and subscription management.
  Enhanced with comprehensive logging and validation for Railway API integration.
  """

  use WebSockex
  require Logger

  @default_log_filter "level:error"
  @reconnect_interval 5_000
  @max_backoff 60_000

  defmodule State do
    @moduledoc false
    defstruct [
      :project_id,
      :service_id,
      :environment_id,
      :token,
      :endpoint,
      subscriptions: %{},
      subscription_counter: 0,
      reconnect_attempts: 0,
      parent_pid: nil,
      connection_acknowledged: false,
      pending_subscriptions: []
    ]
  end

  # Client API

  def start_link(opts) do
    project_id = Keyword.fetch!(opts, :project_id)
    service_id = Keyword.fetch!(opts, :service_id)
    token = Keyword.fetch!(opts, :token)
    environment_id = Keyword.get(opts, :environment_id)
    endpoint = Keyword.get(opts, :endpoint, "wss://backboard.railway.app/graphql/v2")

    # Validate required parameters before attempting connection
    Logger.info(
      "Starting Railway WebSocket connection with project_id: #{project_id}, service_id: #{service_id}"
    )

    if !project_id || project_id == "" do
      Logger.error(
        "WebSocket connection failed: project_id is required but was: #{inspect(project_id)}"
      )

      raise ArgumentError, "project_id is required for WebSocket connection"
    end

    if !service_id || service_id == "" do
      Logger.error(
        "WebSocket connection failed: service_id is required but was: #{inspect(service_id)}"
      )

      raise ArgumentError, "service_id is required for WebSocket connection"
    end

    if !token || token == "" do
      Logger.error(
        "WebSocket connection failed: token is required but was: #{inspect(String.slice(token || "", 0, 10))}..."
      )

      raise ArgumentError, "token is required for WebSocket connection"
    end

    Logger.info("Attempting WebSocket connection to: #{endpoint}")

    state = %State{
      project_id: project_id,
      service_id: service_id,
      environment_id: environment_id,
      token: token,
      endpoint: endpoint,
      parent_pid: self()
    }

    try do
      # Railway uses graphql-transport-ws protocol (newer)
      # Token is passed via Authorization header and connection_init payload (not URL)
      WebSockex.start_link(
        endpoint,
        __MODULE__,
        state,
        name: via_tuple(project_id, service_id),
        extra_headers: [
          {"Sec-WebSocket-Protocol", "graphql-transport-ws"},
          {"Authorization", "Bearer #{token}"}
        ]
      )
    catch
      error ->
        Logger.error(
          "Failed to start WebSocket connection for project #{project_id}, service #{service_id}: #{inspect(error)}"
        )

        {:error, error}
    end
  end

  @doc """
  Subscribe to environment logs (preferred over deploymentLogs).
  Accepts optional `:filter` (string) to let the server filter logs, defaulting
  to only `severity:error` for efficiency.
  """
  def subscribe_to_logs(pid, environment_id, opts \\ []) do
    WebSockex.cast(pid, {:subscribe, environment_id, normalize_opts(opts)})
  end

  def unsubscribe_from_logs(pid, subscription_id) do
    WebSockex.cast(pid, {:unsubscribe, subscription_id})
  end

  @doc """
  Run a sanity check query to verify WebSocket connection and fetch deployment info.
  Returns deployment details including project_id, service_id, environment_id, and status.
  """
  def run_sanity_check(pid, deployment_id) do
    WebSockex.cast(pid, {:sanity_check, deployment_id})
  end

  def connected?(pid) do
    WebSockex.cast(pid, :ping)
    true
  catch
    :exit, _ -> false
  end

  defp via_tuple(project_id, service_id) do
    {:via, Registry, {RailwayApp.Registry, :"websocket_#{project_id}_#{service_id}"}}
  end

  # WebSockex Callbacks

  @impl true
  def handle_connect(_conn, state) do
    Logger.info(
      "Railway WebSocket connected for project #{state.project_id}, service #{state.service_id}"
    )

    # Send connection_init message for GraphQL WebSocket subprotocol
    # We need to use Process.send to send the initial frame, not return it from handle_connect
    Process.send(self(), :send_connection_init, [])

    state = %{state | reconnect_attempts: 0}
    {:ok, state}
  end

  @impl true
  def handle_frame({:text, msg}, state) do
    case Jason.decode(msg) do
      {:ok, %{"type" => "connection_ack"}} ->
        Logger.info(
          "Railway WebSocket connection acknowledged for project #{state.project_id}, service #{state.service_id}"
        )

        # Mark connection as acknowledged and process any pending subscriptions
        new_state = %{state | connection_acknowledged: true}

        # Send any pending subscriptions
        Enum.each(state.pending_subscriptions, fn {environment_id, opts} ->
          Logger.info("Processing pending subscription for environment #{environment_id}")
          WebSockex.cast(self(), {:subscribe, environment_id, opts})
        end)

        {:ok, %{new_state | pending_subscriptions: []}}

      # graphql-transport-ws protocol uses "next" for data
      {:ok, %{"type" => "next", "id" => id, "payload" => payload}} when is_binary(id) ->
        if String.starts_with?(id, "sanity_check_") do
          handle_sanity_check_response(payload, state)
        else
          handle_log_data(payload, state)
        end

      {:ok, %{"type" => "next", "payload" => payload}} ->
        handle_log_data(payload, state)

      # Also handle legacy "data" type for backwards compatibility
      {:ok, %{"type" => "data", "id" => id, "payload" => payload}} when is_binary(id) ->
        if String.starts_with?(id, "sanity_check_") do
          handle_sanity_check_response(payload, state)
        else
          handle_log_data(payload, state)
        end

      {:ok, %{"type" => "data", "payload" => payload}} ->
        handle_log_data(payload, state)

      {:ok, %{"type" => "error", "id" => id, "payload" => payload}} ->
        Logger.error("Railway WebSocket subscription error (#{id}): #{inspect(payload)}")
        {:ok, state}

      {:ok, %{"type" => "error", "payload" => payload}} ->
        Logger.error("Railway WebSocket error: #{inspect(payload)}")
        {:ok, state}

      {:ok, %{"type" => "complete", "id" => id}} ->
        Logger.info("Railway WebSocket subscription #{id} completed")
        {:ok, state}

      {:ok, %{"type" => "complete"}} ->
        Logger.info("Railway WebSocket subscription completed")
        {:ok, state}

      {:ok, other} ->
        Logger.info("Received unhandled Railway WebSocket message type: #{inspect(other)}")
        {:ok, state}

      {:error, reason} ->
        Logger.error("Failed to decode Railway WebSocket message: #{inspect(reason)}")
        {:ok, state}
    end
  end

  @impl true
  def handle_frame({:binary, data}, state) do
    Logger.debug("Received binary data: #{byte_size(data)} bytes")
    {:ok, state}
  end

  @impl true
  def handle_cast({:subscribe, environment_id, opts}, state) do
    opts = normalize_opts(opts)

    # Queue subscription if connection not yet acknowledged
    if not state.connection_acknowledged do
      Logger.info("Connection not yet acknowledged, queueing subscription for #{environment_id}")

      new_state = %{
        state
        | pending_subscriptions: [{environment_id, opts} | state.pending_subscriptions]
      }

      {:ok, new_state}
    else
      do_subscribe(environment_id, state, opts)
    end
  end

  @impl true
  def handle_cast({:unsubscribe, subscription_id}, state) do
    if Map.has_key?(state.subscriptions, subscription_id) do
      # graphql-transport-ws protocol (newer) uses "complete"
      payload = %{
        "id" => subscription_id,
        "type" => "complete"
      }

      frame = {:text, Jason.encode!(payload)}
      new_state = %{state | subscriptions: Map.delete(state.subscriptions, subscription_id)}

      Logger.info("Unsubscribed from subscription #{subscription_id}")
      {:reply, frame, new_state}
    else
      Logger.warning("Unknown subscription ID: #{subscription_id}", %{})
      {:ok, state}
    end
  end

  @impl true
  def handle_cast(:ping, state) do
    {:reply, :ping, state}
  end

  @impl true
  def handle_cast({:sanity_check, deployment_id}, state) do
    query_id = "sanity_check_#{System.system_time(:millisecond)}"

    # GraphQL query to fetch deployment information
    query = """
    query GetDeployment($deploymentId: String!) {
      deployment(id: $deploymentId) {
        id
        projectId
        serviceId
        environmentId
        status
      }
    }
    """

    variables = %{
      "deploymentId" => deployment_id
    }

    # graphql-transport-ws protocol (newer) uses "subscribe"
    payload = %{
      "id" => query_id,
      "type" => "subscribe",
      "payload" => %{
        "query" => query,
        "variables" => variables
      }
    }

    frame = {:text, Jason.encode!(payload)}

    Logger.info("Running sanity check for deployment #{deployment_id} (query: #{query_id})")
    {:reply, frame, state}
  end

  @impl true
  def handle_info(:send_connection_init, state) do
    Logger.info("Sending connection_init message to Railway WebSocket")

    # Pass the authentication token in the connection_init payload
    # This is required by the graphql-transport-ws protocol
    frame =
      {:text,
       Jason.encode!(%{
         "type" => "connection_init",
         "payload" => %{
           "token" => state.token
         }
       })}

    {:reply, frame, state}
  end

  @impl true
  def handle_info({:reconnect, project_id, service_id, _token, endpoint}, state) do
    Logger.info(
      "Attempting to reconnect Railway WebSocket for project #{project_id}, service #{service_id} (attempt #{state.reconnect_attempts + 1})"
    )

    Logger.info("Reconnecting to WebSocket: #{endpoint}")

    try do
      # Railway uses graphql-transport-ws protocol (newer)
      # Token is passed via Authorization header and connection_init payload (not URL)
      case WebSockex.start_link(
             endpoint,
             __MODULE__,
             state,
             extra_headers: [
               {"Sec-WebSocket-Protocol", "graphql-transport-ws"},
               {"Authorization", "Bearer #{state.token}"}
             ]
           ) do
        {:ok, _pid} ->
          Logger.info(
            "Successfully reconnected Railway WebSocket for project #{project_id}, service #{service_id}"
          )

          {:noreply, %{state | reconnect_attempts: 0}}

        {:error, reason} ->
          Logger.error(
            "Failed to reconnect Railway WebSocket for project #{project_id}, service #{service_id}: #{inspect(reason)}"
          )

          # Schedule another reconnection with longer backoff
          backoff_interval = calculate_backoff_interval(state.reconnect_attempts + 1)
          Logger.info("Scheduling next reconnection attempt in #{backoff_interval}ms")

          schedule_reconnect(
            self(),
            project_id,
            service_id,
            state.token,
            endpoint,
            backoff_interval
          )

          new_state = %{state | reconnect_attempts: state.reconnect_attempts + 1}
          {:noreply, new_state}
      end
    catch
      error ->
        Logger.error(
          "Exception during Railway WebSocket reconnection for project #{project_id}, service #{service_id}: #{inspect(error)}"
        )

        backoff_interval = calculate_backoff_interval(state.reconnect_attempts + 1)

        schedule_reconnect(
          self(),
          project_id,
          service_id,
          state.token,
          endpoint,
          backoff_interval
        )

        new_state = %{state | reconnect_attempts: state.reconnect_attempts + 1}
        {:noreply, new_state}
    end
  end

  @impl true
  def handle_disconnect(%{reason: reason}, state) do
    Logger.error(
      "Railway WebSocket disconnected for project #{state.project_id}, service #{state.service_id}. Reason: #{inspect(reason)}"
    )

    if state.parent_pid do
      send(state.parent_pid, {:websocket_disconnected, self(), reason})
    end

    # Schedule reconnection with exponential backoff
    backoff_interval = calculate_backoff_interval(state.reconnect_attempts + 1)

    Logger.info(
      "Scheduling reconnection for project #{state.project_id}, service #{state.service_id} in #{backoff_interval}ms (attempt #{state.reconnect_attempts + 1})"
    )

    schedule_reconnect(
      self(),
      state.project_id,
      state.service_id,
      state.token,
      state.endpoint,
      backoff_interval
    )

    new_state = %{state | reconnect_attempts: state.reconnect_attempts + 1}
    {:ok, new_state}
  end

  # Private Functions

  defp do_subscribe(environment_id, state, opts) do
    subscription_id = "sub_#{state.subscription_counter}"
    new_counter = state.subscription_counter + 1

    # GraphQL subscription for Railway environment logs
    # This covers all deployments within the environment
    subscription_query = """
    subscription EnvironmentLogs($environmentId: String!, $filter: String) {
      environmentLogs(environmentId: $environmentId, filter: $filter) {
        message
        timestamp
        severity
      }
    }
    """

    filter =
      opts
      |> Map.get(:filter)
      |> case do
        nil ->
          case Map.get(opts, "filter") do
            nil -> @default_log_filter
            value -> value
          end

        value ->
          value
      end

    variables = %{
      "environmentId" => environment_id,
      "filter" => filter
    }

    # graphql-transport-ws protocol (newer) uses "subscribe"
    payload = %{
      "id" => subscription_id,
      "type" => "subscribe",
      "payload" => %{
        "query" => subscription_query,
        "variables" => variables
      }
    }

    frame = {:text, Jason.encode!(payload)}

    new_state = %{
      state
      | subscription_counter: new_counter,
        subscriptions:
          Map.put(state.subscriptions, subscription_id, %{
            environment_id: environment_id,
            query: subscription_query,
            variables: variables,
            started_at: DateTime.utc_now()
          })
    }

    Logger.info(
      "Sending subscription request for environment #{environment_id} (sub: #{subscription_id})"
    )

    {:reply, frame, new_state}
  end

  defp handle_sanity_check_response(payload, state) do
    case payload do
      %{"data" => %{"deployment" => deployment}} when is_map(deployment) ->
        Logger.info("""
        ✅ WebSocket Sanity Check PASSED
        ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        Deployment ID:  #{deployment["id"]}
        Project ID:     #{deployment["projectId"]}
        Service ID:     #{deployment["serviceId"] || "N/A"}
        Environment ID: #{deployment["environmentId"]}
        Status:         #{deployment["status"]}
        ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        """)

        # Broadcast sanity check result
        Phoenix.PubSub.broadcast(
          RailwayApp.PubSub,
          "railway:sanity_check:#{state.service_id}",
          {:sanity_check_result, :ok, deployment}
        )

      %{"errors" => errors} ->
        Logger.error("❌ WebSocket Sanity Check FAILED: #{inspect(errors)}")

        Phoenix.PubSub.broadcast(
          RailwayApp.PubSub,
          "railway:sanity_check:#{state.service_id}",
          {:sanity_check_result, :error, errors}
        )

      other ->
        Logger.warning("Unexpected sanity check response: #{inspect(other)}", %{})
    end

    {:ok, state}
  end

  @doc false
  def handle_log_data(payload, state) do
    # Handle both environmentLogs and deploymentLogs responses
    logs =
      case payload do
        %{"data" => %{"environmentLogs" => logs}} when is_list(logs) -> logs
        %{"data" => %{"deploymentLogs" => logs}} when is_list(logs) -> logs
        _ -> []
      end

    case logs do
      logs when is_list(logs) and length(logs) > 0 ->
        for log <- logs do
          %{
            # Generate ID as it's not in the response
            id: Ecto.UUID.generate(),
            timestamp: parse_timestamp(log["timestamp"]),
            message: log["message"],
            # Map severity to level
            level: log["severity"] || "info",
            service_id: state.service_id,
            environment_id: state.environment_id,
            # Default source
            source: "stdout",
            meta: %{}
          }
        end
        |> Enum.reject(fn log_event ->
          # Filter out logs from the agent itself to prevent infinite loops
          # We check if the service_id matches the agent's own project/service ID
          # or if the log message contains specific signatures of the agent's own logging
          agent_service_id = System.get_env("RAILWAY_SERVICE_ID")

          is_agent_log =
            (agent_service_id && log_event.service_id == agent_service_id) ||
              String.contains?(log_event.message, "Analyzing") ||
              String.contains?(log_event.message, "Incident confidence") ||
              String.contains?(log_event.message, "Created incident")

          if is_agent_log do
            Logger.debug(
              "Ignoring agent's own log to prevent loop: #{String.slice(log_event.message, 0, 50)}..."
            )
          end

          is_agent_log
        end)
        |> Enum.each(fn log_event ->
          # Broadcast to PubSub for LiveView updates (service-specific)
          Phoenix.PubSub.broadcast(
            RailwayApp.PubSub,
            "railway:logs:#{state.service_id}",
            {:log_event, log_event}
          )

          # Broadcast to global topic for LogProcessor
          Phoenix.PubSub.broadcast(
            RailwayApp.PubSub,
            "railway:logs",
            {:log_event, log_event}
          )
        end)

      _ ->
        # Empty logs or no logs to process
        :ok
    end

    # Handle GraphQL errors separately
    case payload do
      %{"errors" => errors} ->
        Logger.error("GraphQL errors in log data: #{inspect(errors)}")

      _ ->
        :ok
    end

    {:ok, state}
  end

  defp normalize_opts(%{} = opts), do: opts
  defp normalize_opts(opts) when is_list(opts), do: Map.new(opts)
  defp normalize_opts(_), do: %{}

  defp parse_timestamp(nil), do: DateTime.utc_now()

  defp parse_timestamp(timestamp) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, dt, _} -> dt
      {:error, _} -> DateTime.utc_now()
    end
  end

  defp parse_timestamp(_), do: DateTime.utc_now()

  defp calculate_backoff_interval(attempt) do
    # Exponential backoff: 5s * 2^(attempt-1), max 60s
    base_interval = @reconnect_interval
    max_interval = @max_backoff

    backoff = min(base_interval * :math.pow(2, attempt - 1), max_interval)
    round(backoff)
  end

  defp schedule_reconnect(
         pid,
         project_id,
         service_id,
         token,
         endpoint,
         interval
       ) do
    Process.send_after(
      pid,
      {:reconnect, project_id, service_id, token, endpoint},
      interval
    )
  end
end
