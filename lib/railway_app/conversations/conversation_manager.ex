defmodule RailwayApp.Conversations.ConversationManager do
  @moduledoc """
  Manages conversational interactions with users via Slack.
  Handles command parsing, execution, and response generation.
  """

  use GenServer
  require Logger

  alias RailwayApp.{Conversations, Incidents}
  alias RailwayApp.Analysis.LLMRouter
  alias RailwayApp.Alerts.SlackNotifier
  alias RailwayApp.Railway.Client

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    # Subscribe to conversation events
    Phoenix.PubSub.subscribe(RailwayApp.PubSub, "conversations:events")

    {:ok, %{}}
  end

  @impl true
  def handle_info({:start_chat, incident_id, channel_id, user_id, thread_ts}, state) do
    Logger.info("Starting chat for incident #{incident_id}")

    # Create or get existing session
    session_key = "#{channel_id}:#{thread_ts}"

    session =
      case Conversations.get_session_by_channel_ref(session_key) do
        nil ->
          {:ok, session} =
            Conversations.create_session(%{
              incident_id: incident_id,
              channel: "slack",
              channel_ref: session_key,
              participant_id: user_id,
              started_at: DateTime.utc_now()
            })

          session

        existing ->
          existing
      end

    # Send welcome message
    incident = Incidents.get_incident(incident_id)

    SlackNotifier.send_message(
      channel_id,
      "👋 Hi! I'm here to help with this incident. You can:\n\n" <>
        "*Information:*\n" <>
        "• `status` - Get current service status\n" <>
        "• `logs` - View recent logs\n" <>
        "• `deployments` - List recent deployments\n" <>
        "• `help` - Show all commands\n\n" <>
        "Just type your question or command and I'll do my best to help!",
      thread_ts
    )

    # Log system message
    Conversations.create_message(%{
      session_id: session.id,
      role: "system",
      content: "Chat session started for incident: #{incident.service_name}",
      timestamp: DateTime.utc_now()
    })

    {:noreply, state}
  end

  @impl true
  def handle_info({:slash_command, command, text, user_id, channel_id, response_url}, state) do
    Logger.info("Processing slash command: #{command} #{text}")

    # Get or create session for this user
    session_key = "#{channel_id}:slash:#{user_id}"

    session =
      case Conversations.get_session_by_channel_ref(session_key) do
        nil ->
          {:ok, session} =
            Conversations.create_session(%{
              channel: "slack",
              channel_ref: session_key,
              participant_id: user_id,
              started_at: DateTime.utc_now()
            })

          session

        existing ->
          existing
      end

    # Process command
    process_user_message(session, text, channel_id, nil, response_url)

    {:noreply, state}
  end

  @impl true
  def handle_info({:thread_message, channel_id, user_id, text, thread_ts, _message_ts}, state) do
    Logger.info("Processing threaded message from user #{user_id} in channel #{channel_id}")

    # Find existing session by thread reference
    session_key = "#{channel_id}:#{thread_ts}"

    case Conversations.get_session_by_channel_ref(session_key) do
      nil ->
        # No existing session - create a new one (user may have started typing without clicking Start Chat)
        Logger.info("No existing session found for thread #{thread_ts}, creating new session")

        {:ok, session} =
          Conversations.create_session(%{
            channel: "slack",
            channel_ref: session_key,
            participant_id: user_id,
            started_at: DateTime.utc_now()
          })

        process_user_message(session, text, channel_id, thread_ts, nil)

      session ->
        # Existing session found - continue the conversation
        Logger.info("Found existing session #{session.id} for thread")
        process_user_message(session, text, channel_id, thread_ts, nil)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("Unhandled message in ConversationManager: #{inspect(msg)}")
    {:noreply, state}
  end

  # Private Functions

  defp process_user_message(session, message, channel_id, thread_ts, response_url) do
    # Save user message
    Conversations.create_message(%{
      session_id: session.id,
      role: "user",
      content: message,
      timestamp: DateTime.utc_now()
    })

    # Parse intent using LLM
    Task.Supervisor.start_child(RailwayApp.TaskSupervisor, fn ->
      context = %{
        session_id: session.id,
        incident_id: session.incident_id
      }

      case LLMRouter.parse_intent(message, context) do
        {:ok, intent_data} ->
          handle_intent(
            session,
            intent_data,
            message,
            channel_id,
            thread_ts,
            response_url
          )

        {:error, _reason} ->
          # Fallback to simple pattern matching
          handle_simple_intent(session, message, channel_id, thread_ts, response_url)
      end
    end)
  end

  defp handle_intent(session, intent_data, _original_message, channel_id, thread_ts, response_url) do
    intent = intent_data[:intent] || intent_data["intent"]

    service_id =
      intent_data[:service] || intent_data["service"] || get_service_from_session(session)

    params = intent_data[:parameters] || intent_data["parameters"] || %{}

    response =
      case intent do
        "restart" ->
          execute_command(:restart, service_id, session)

        "redeploy" ->
          execute_command(:redeploy, service_id, session)

        "scale" ->
          scale_type = params[:type] || params["type"] || "memory"
          value = params[:value] || params["value"]
          execute_command({:scale, scale_type, value}, service_id, session)

        "rollback" ->
          execute_command(:rollback, service_id, session)

        "stop" ->
          execute_command(:stop, service_id, session)

        "status" ->
          execute_command(:status, service_id, session)

        "logs" ->
          limit = params[:limit] || params["limit"] || 20
          execute_command({:logs, limit}, service_id, session)

        "deployments" ->
          limit = params[:limit] || params["limit"] || 5
          execute_command({:deployments, limit}, service_id, session)

        "help" ->
          get_help_message()

        _ ->
          "I'm not sure how to help with that. Type `help` to see available commands."
      end

    # Save assistant response
    Conversations.create_message(%{
      session_id: session.id,
      role: "assistant",
      content: response,
      timestamp: DateTime.utc_now()
    })

    # Send response to Slack
    if response_url do
      send_delayed_response(response_url, response)
    else
      SlackNotifier.send_message(channel_id, response, thread_ts)
    end
  end

  defp get_service_from_session(session) do
    # Try to get service_id from the associated incident
    if session.incident_id do
      case Incidents.get_incident(session.incident_id) do
        nil -> nil
        incident -> incident.service_id
      end
    else
      nil
    end
  end

  defp handle_simple_intent(session, message, channel_id, thread_ts, response_url) do
    message_lower = String.downcase(message)
    service_id = get_service_from_session(session)

    # Try to extract value from message (e.g., "scale memory 2048")
    value = extract_numeric_value(message)

    response =
      cond do
        String.contains?(message_lower, "restart") ->
          if service_id do
            execute_command(:restart, service_id, session)
          else
            "To restart a service, please specify which service you'd like to restart."
          end

        String.contains?(message_lower, "redeploy") ->
          if service_id do
            execute_command(:redeploy, service_id, session)
          else
            "To redeploy a service, please specify which service."
          end

        String.contains?(message_lower, "stop") ->
          if service_id do
            execute_command(:stop, service_id, session)
          else
            "⚠️ To stop a service, please specify which service. This is an emergency action."
          end

        String.contains?(message_lower, ["scale memory", "memory"]) and
            String.contains?(message_lower, "scale") ->
          if service_id do
            execute_command({:scale, "memory", value}, service_id, session)
          else
            "To scale memory, please specify the service and amount (e.g., `scale memory 2048`)."
          end

        String.contains?(message_lower, ["scale replicas", "replicas"]) and
            String.contains?(message_lower, "scale") ->
          if service_id do
            execute_command({:scale, "replicas", value}, service_id, session)
          else
            "To scale replicas, please specify the service and count (e.g., `scale replicas 3`)."
          end

        String.contains?(message_lower, "rollback") ->
          if service_id do
            execute_command(:rollback, service_id, session)
          else
            "To rollback a deployment, please specify which service."
          end

        String.contains?(message_lower, ["logs", "log"]) ->
          if service_id do
            execute_command({:logs, value || 20}, service_id, session)
          else
            "To view logs, please specify which service."
          end

        String.contains?(message_lower, ["deployments", "deployment"]) ->
          if service_id do
            execute_command({:deployments, value || 5}, service_id, session)
          else
            "To list deployments, please specify which service."
          end

        String.contains?(message_lower, ["status", "health"]) ->
          if service_id do
            execute_command(:status, service_id, session)
          else
            "To check service status, please specify which service."
          end

        String.contains?(message_lower, ["help", "what can you do", "commands"]) ->
          get_help_message()

        true ->
          "I can help you manage your Railway services. Type `help` to see available commands."
      end

    # Save messages
    Conversations.create_message(%{
      session_id: session.id,
      role: "assistant",
      content: response,
      timestamp: DateTime.utc_now()
    })

    # Send response
    if response_url do
      send_delayed_response(response_url, response)
    else
      SlackNotifier.send_message(channel_id, response, thread_ts)
    end
  end

  defp extract_numeric_value(message) do
    case Regex.run(~r/\b(\d+)\b/, message) do
      [_, value] -> String.to_integer(value)
      _ -> nil
    end
  end

  defp execute_command(:restart, nil, _session) do
    "❌ No service specified. Please provide a service ID or use this command in an incident thread."
  end

  defp execute_command(:restart, service_id, session) do
    environment_id = get_environment_from_session(session)

    if environment_id do
      case Client.restart_service(service_id, environment_id) do
        {:ok, _} ->
          "✅ Service restart initiated for `#{service_id}`"

        {:error, reason} ->
          "❌ Failed to restart service: #{format_error(reason)}"
      end
    else
      "❌ Could not determine environment. Please specify the environment or use this command in an incident thread."
    end
  end

  defp execute_command(:redeploy, nil, _session) do
    "❌ No service specified. Please provide a service ID."
  end

  defp execute_command(:redeploy, service_id, session) do
    # Get the latest deployment ID first
    environment_id = get_environment_from_session(session)

    case get_latest_deployment_for_service(service_id, environment_id) do
      {:ok, deployment_id} ->
        case Client.redeploy_deployment(deployment_id) do
          {:ok, %{"deploymentRedeploy" => %{"id" => new_id}}} ->
            "✅ Redeploy initiated for `#{service_id}`\nNew deployment ID: `#{new_id}`"

          {:ok, _} ->
            "✅ Redeploy initiated for `#{service_id}`"

          {:error, reason} ->
            "❌ Failed to redeploy: #{format_error(reason)}"
        end

      {:error, reason} ->
        "❌ Could not find deployment to redeploy: #{format_error(reason)}"
    end
  end

  defp execute_command(:stop, nil, _session) do
    "❌ No service specified. Please provide a service ID."
  end

  defp execute_command(:stop, service_id, session) do
    environment_id = get_environment_from_session(session)

    case get_latest_deployment_for_service(service_id, environment_id) do
      {:ok, deployment_id} ->
        case Client.stop_deployment(deployment_id) do
          {:ok, _} ->
            "🛑 Service stopped for `#{service_id}`\n⚠️ The service will need to be manually restarted."

          {:error, reason} ->
            "❌ Failed to stop service: #{format_error(reason)}"
        end

      {:error, reason} ->
        "❌ Could not find deployment to stop: #{format_error(reason)}"
    end
  end

  defp execute_command({:scale, "memory", value}, nil, _session) do
    "❌ No service specified. Usage: `scale memory <MB>` (e.g., `scale memory #{value || 2048}`)"
  end

  defp execute_command({:scale, "memory", value}, service_id, _session) do
    memory_mb = value || 2048

    case Client.scale_memory(service_id, memory_mb) do
      {:ok, _} ->
        "✅ Memory scaled to #{memory_mb} MB for `#{service_id}`"

      {:error, reason} ->
        "❌ Failed to scale memory: #{format_error(reason)}"
    end
  end

  defp execute_command({:scale, "replicas", value}, nil, _session) do
    "❌ No service specified. Usage: `scale replicas <count>` (e.g., `scale replicas #{value || 2}`)"
  end

  defp execute_command({:scale, "replicas", value}, service_id, session) do
    replica_count = value || 2
    environment_id = get_environment_from_session(session)

    if environment_id do
      case Client.scale_replicas(service_id, environment_id, replica_count) do
        {:ok, _} ->
          "✅ Scaled to #{replica_count} replicas for `#{service_id}`"

        {:error, reason} ->
          "❌ Failed to scale replicas: #{format_error(reason)}"
      end
    else
      "❌ Could not determine environment. Please specify the environment or use this command in an incident thread."
    end
  end

  defp execute_command(:rollback, nil, _session) do
    "❌ No service specified. Please provide a service ID."
  end

  defp execute_command(:rollback, service_id, _session) do
    case Client.get_deployments(service_id, 5) do
      {:ok, %{"service" => %{"deployments" => %{"edges" => edges}}}} ->
        case find_previous_deployment(edges) do
          nil ->
            "❌ No previous successful deployment found to rollback to"

          deployment_id ->
            case Client.rollback_deployment(deployment_id) do
              {:ok, _} ->
                "✅ Rollback initiated for `#{service_id}`\nRolling back to deployment `#{deployment_id}`"

              {:error, reason} ->
                "❌ Failed to rollback: #{format_error(reason)}"
            end
        end

      {:error, reason} ->
        "❌ Failed to fetch deployments: #{format_error(reason)}"
    end
  end

  defp execute_command(:status, nil, _session) do
    "❌ No service specified. Please provide a service ID."
  end

  defp execute_command(:status, service_id, session) do
    environment_id = get_environment_from_session(session)

    if environment_id do
      case Client.get_service_instance(environment_id, service_id) do
        {:ok, %{"serviceInstance" => instance}} when not is_nil(instance) ->
          format_service_status(instance)

        {:ok, _} ->
          "❌ Service instance not found for `#{service_id}`"

        {:error, reason} ->
          "❌ Failed to get service status: #{format_error(reason)}"
      end
    else
      # Fallback to basic service state
      case Client.get_service_state(service_id) do
        {:ok, data} ->
          format_basic_service_status(data)

        {:error, reason} ->
          "❌ Failed to get service status: #{format_error(reason)}"
      end
    end
  end

  defp execute_command({:logs, limit}, nil, _session) do
    "❌ No service specified. Usage: `logs` or `logs <count>` (e.g., `logs #{limit}`)"
  end

  defp execute_command({:logs, limit}, service_id, session) do
    environment_id = get_environment_from_session(session)

    case get_latest_deployment_for_service(service_id, environment_id) do
      {:ok, deployment_id} ->
        case Client.get_deployment_logs(deployment_id, limit: limit) do
          {:ok, %{"deploymentLogs" => logs}} when is_list(logs) and length(logs) > 0 ->
            format_logs(logs, limit)

          {:ok, _} ->
            "📜 No recent logs found for `#{service_id}`"

          {:error, reason} ->
            "❌ Failed to fetch logs: #{format_error(reason)}"
        end

      {:error, reason} ->
        "❌ Could not find deployment for logs: #{format_error(reason)}"
    end
  end

  defp execute_command({:deployments, _limit}, nil, _session) do
    "❌ No service specified. Usage: `deployments` or `deployments <count>`"
  end

  defp execute_command({:deployments, limit}, service_id, _session) do
    case Client.get_deployments(service_id, limit) do
      {:ok, %{"service" => %{"deployments" => %{"edges" => edges}}}} when is_list(edges) ->
        format_deployments(edges)

      {:ok, _} ->
        "📦 No deployments found for `#{service_id}`"

      {:error, reason} ->
        "❌ Failed to fetch deployments: #{format_error(reason)}"
    end
  end

  defp get_environment_from_session(session) do
    if session.incident_id do
      case Incidents.get_incident(session.incident_id) do
        nil -> nil
        incident -> incident.environment_id
      end
    else
      nil
    end
  end

  defp get_latest_deployment_for_service(service_id, environment_id) do
    if environment_id do
      # Use the proper method with environment
      config = Application.get_env(:railway_app, :railway, [])
      project_id = config[:project_id]
      Client.get_latest_deployment_id(project_id, environment_id, service_id)
    else
      # Fallback: get deployments and take the first one
      case Client.get_deployments(service_id, 1) do
        {:ok, %{"service" => %{"deployments" => %{"edges" => [%{"node" => %{"id" => id}} | _]}}}} ->
          {:ok, id}

        _ ->
          {:error, :no_deployment_found}
      end
    end
  end

  defp format_service_status(instance) do
    deployment = instance["latestDeployment"] || %{}
    domains = instance["domains"] || %{}
    service_domains = domains["serviceDomains"] || []

    domain_list =
      service_domains
      |> Enum.map(fn d -> d["domain"] end)
      |> Enum.join(", ")

    """
    📊 *Service Status*

    *Service:* `#{instance["serviceName"] || instance["serviceId"]}`
    *Region:* #{instance["region"] || "default"}
    *Replicas:* #{instance["numReplicas"] || 1}

    *Latest Deployment:*
    • Status: #{deployment["status"] || "Unknown"}
    • Created: #{deployment["createdAt"] || "N/A"}
    • URL: #{deployment["url"] || "N/A"}

    *Domains:* #{if domain_list != "", do: domain_list, else: "None configured"}
    """
  end

  defp format_basic_service_status(data) do
    service = data["service"] || %{}

    """
    📊 *Service Status*

    *Service ID:* `#{service["id"] || "Unknown"}`
    *Status:* #{service["status"] || "Unknown"}

    _For detailed metrics, check the Railway dashboard._
    """
  end

  defp format_logs(logs, limit) do
    log_text =
      logs
      |> Enum.take(limit)
      |> Enum.map(fn log ->
        severity_emoji =
          case log["severity"] do
            "error" -> "🔴"
            "warn" -> "🟡"
            "info" -> "🔵"
            _ -> "⚪"
          end

        timestamp =
          case log["timestamp"] do
            nil -> ""
            ts -> "[#{String.slice(ts, 11, 8)}]"
          end

        "#{severity_emoji} #{timestamp} #{String.slice(log["message"] || "", 0, 100)}"
      end)
      |> Enum.join("\n")

    """
    📜 *Recent Logs* (#{min(length(logs), limit)} entries)

    ```
    #{log_text}
    ```
    """
  end

  defp format_deployments(edges) do
    deployment_text =
      edges
      |> Enum.with_index(1)
      |> Enum.map(fn {%{"node" => dep}, idx} ->
        status_emoji =
          case dep["status"] do
            "SUCCESS" -> "✅"
            "FAILED" -> "❌"
            "BUILDING" -> "🔨"
            "DEPLOYING" -> "🚀"
            _ -> "⚪"
          end

        "#{idx}. #{status_emoji} `#{dep["id"]}` - #{dep["status"]} (#{dep["createdAt"]})"
      end)
      |> Enum.join("\n")

    """
    📦 *Recent Deployments*

    #{deployment_text}
    """
  end

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)

  defp get_help_message do
    """
    🤖 *Railway Bot Commands*

    *Service Actions:*
    • `restart` - Restart the current deployment
    • `redeploy` - Fresh deploy from source
    • `rollback` - Rollback to previous successful deployment
    • `stop` - Stop the service (emergency use)

    *Scaling:*
    • `scale memory <MB>` - Set memory limit (e.g., `scale memory 2048`)
    • `scale replicas <N>` - Set replica count (e.g., `scale replicas 3`)

    *Information:*
    • `status` - Get current service status and metrics
    • `logs [count]` - View recent logs (default: 20)
    • `deployments [count]` - List recent deployments (default: 5)

    _When used in an incident thread, commands automatically target the affected service._
    """
  end

  defp find_previous_deployment(edges) do
    edges
    |> Enum.find(fn %{"node" => node} -> node["status"] == "SUCCESS" end)
    |> case do
      %{"node" => %{"id" => id}} -> id
      _ -> nil
    end
  end

  defp send_delayed_response(response_url, text) do
    Task.Supervisor.start_child(RailwayApp.TaskSupervisor, fn ->
      Req.post(response_url,
        json: %{
          text: text,
          response_type: "ephemeral"
        }
      )
    end)
  end
end
