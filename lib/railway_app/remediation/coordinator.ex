defmodule RailwayApp.Remediation.Coordinator do
  @moduledoc """
  Coordinates remediation actions for incidents.
  Handles auto-remediation and manual remediation requests.
  """

  use GenServer

  alias RailwayApp.Alerts.SlackNotifier
  alias RailwayApp.Railway.Client
  alias RailwayApp.{Incidents, RemediationActions, ServiceConfigs}

  require Logger

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def execute_remediation(incident_id, initiator_type, initiator_ref \\ nil) do
    GenServer.cast(__MODULE__, {:execute_remediation, incident_id, initiator_type, initiator_ref})
  end

  @impl true
  def init(_opts) do
    # Subscribe to incident and remediation events
    Phoenix.PubSub.subscribe(RailwayApp.PubSub, "incidents:new")
    Phoenix.PubSub.subscribe(RailwayApp.PubSub, "remediation:actions")

    {:ok, %{}}
  end

  @impl true
  def handle_cast({:execute_remediation, incident_id, initiator_type, initiator_ref}, state) do
    case Incidents.get_incident(incident_id) do
      nil ->
        Logger.error("Incident not found: #{incident_id}")

      incident ->
        execute_remediation_action(incident, initiator_type, initiator_ref)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:incident_detected, incident}, state) do
    # Check if auto-remediation is enabled for this service
    case ServiceConfigs.get_by_service_id(incident.service_id) do
      nil ->
        Logger.warning("No service config found for #{incident.service_id}", %{})

      service_config ->
        if service_config.auto_remediation_enabled && incident.recommended_action != "manual_fix" do
          Logger.info("Auto-remediation enabled for incident #{incident.id}")
          execute_remediation_action(incident, "automated", "system")
        else
          Logger.info(
            "Auto-remediation disabled or manual fix required for incident #{incident.id}"
          )
        end
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:auto_fix_requested, incident_id, initiator}, state) do
    Logger.info("Manual auto-fix requested for incident #{incident_id}")
    execute_remediation(incident_id, "user", initiator)
    {:noreply, state}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("Unhandled message in Coordinator: #{inspect(msg)}")
    {:noreply, state}
  end

  # Private Functions

  defp execute_remediation_action(incident, initiator_type, initiator_ref) do
    Logger.info(
      "Executing remediation for incident #{incident.id}: #{incident.recommended_action}"
    )

    start_time = System.monotonic_time()

    # Create remediation action record
    {:ok, action} =
      RemediationActions.create_remediation_action(%{
        incident_id: incident.id,
        initiator_type: initiator_type,
        initiator_ref: initiator_ref,
        action_type: incident.recommended_action,
        status: "pending",
        requested_at: DateTime.utc_now()
      })

    # Update action status to in_progress
    {:ok, action} = RemediationActions.update_remediation_action(action, %{status: "in_progress"})

    # Execute the action in a supervised task
    Task.Supervisor.start_child(RailwayApp.TaskSupervisor, fn ->
      result = perform_action(incident, action)
      finalize_action(incident, action, result, start_time)
    end)
  end

  defp perform_action(incident, action) do
    # Get environment_id from incident or fetch from service config
    environment_id = get_environment_id(incident)

    case action.action_type do
      "restart" ->
        if environment_id do
          Client.restart_service(incident.service_id, environment_id)
        else
          {:error, "Missing environment_id for restart action"}
        end

      "redeploy" ->
        if environment_id do
          Client.restart_service(incident.service_id, environment_id)
        else
          {:error, "Missing environment_id for redeploy action"}
        end

      "scale_memory" ->
        if environment_id do
          service_config = ServiceConfigs.get_by_service_id(incident.service_id)
          memory = service_config.memory_scale_default || 2048
          Client.scale_memory(incident.service_id, environment_id, memory)
        else
          {:error, "Missing environment_id for scale_memory action"}
        end

      "scale_replicas" ->
        if environment_id do
          service_config = ServiceConfigs.get_by_service_id(incident.service_id)
          replicas = service_config.replica_scale_default || 2
          Client.scale_replicas(incident.service_id, environment_id, replicas)
        else
          {:error, "Missing environment_id for scale_replicas action"}
        end

      "rollback" ->
        # Get previous deployment
        case Client.get_deployments(incident.service_id, 5) do
          {:ok, %{"service" => %{"deployments" => %{"edges" => edges}}}} ->
            # Find the last successful deployment before the current one
            case find_previous_successful_deployment(edges) do
              nil ->
                {:error, "No previous successful deployment found"}

              deployment_id ->
                Client.rollback_service(incident.service_id, deployment_id)
            end

          {:error, reason} ->
            {:error, "Failed to fetch deployments: #{inspect(reason)}"}
        end

      "stop" ->
        # Stop is handled as a no-op for now, as Railway doesn't have a direct stop mutation
        # Consider using serviceInstanceDelete or just logging
        Logger.warning(
          "Stop action requested but not implemented - requires manual intervention",
          %{}
        )

        {:ok, "Stop action acknowledged - manual intervention recommended"}

      "none" ->
        {:ok, "No action required"}

      "manual_fix" ->
        {:ok, "Manual fix required - no automated action taken"}

      _ ->
        {:error, "Unknown action type: #{action.action_type}"}
    end
  end

  # Get environment_id from incident or from monitored environments config
  defp get_environment_id(incident) do
    cond do
      incident.environment_id && incident.environment_id != "" ->
        incident.environment_id

      true ->
        # Try to get from monitored environments config
        case System.get_env("RAILWAY_MONITORED_ENVIRONMENTS") do
          nil -> nil
          "" -> nil
          env_str -> env_str |> String.split(",") |> List.first() |> String.trim()
        end
    end
  end

  defp finalize_action(incident, action, result, start_time) do
    # Measure remediation latency (SC-003)
    latency = System.monotonic_time() - start_time

    case result do
      {:ok, response} ->
        Logger.info("Remediation succeeded for incident #{incident.id}")

        # Update action and capture the result for Slack notification
        result_message = format_success_message(response)

        {:ok, updated_action} =
          RemediationActions.update_remediation_action(action, %{
            status: "succeeded",
            completed_at: DateTime.utc_now(),
            result_message: result_message
          })

        {:ok, updated_incident} =
          Incidents.update_incident(incident, %{
            status: "auto_remediated",
            resolved_at: DateTime.utc_now()
          })

        # Record telemetry
        :telemetry.execute(
          [:railway_agent, :remediation, :latency],
          %{duration: latency},
          %{
            action_type: action.action_type,
            initiator_type: action.initiator_type,
            status: "succeeded"
          }
        )

        :telemetry.execute(
          [:railway_agent, :remediation, :success],
          %{count: 1},
          %{action_type: action.action_type}
        )

        :telemetry.execute(
          [:railway_agent, :incident, :resolved],
          %{count: 1},
          %{status: "auto_remediated", service_id: incident.service_id}
        )

        # Send Slack notification with updated action containing result_message
        SlackNotifier.send_remediation_update(updated_incident, updated_action, "succeeded")

      {:error, reason} ->
        Logger.error("Remediation failed for incident #{incident.id}: #{inspect(reason)}")

        # Update action and capture the result for Slack notification
        failure_message = format_failure_message(reason)

        {:ok, updated_action} =
          RemediationActions.update_remediation_action(action, %{
            status: "failed",
            completed_at: DateTime.utc_now(),
            failure_reason: failure_message
          })

        {:ok, updated_incident} = Incidents.update_incident(incident, %{status: "failed"})

        # Record telemetry
        :telemetry.execute(
          [:railway_agent, :remediation, :latency],
          %{duration: latency},
          %{
            action_type: action.action_type,
            initiator_type: action.initiator_type,
            status: "failed"
          }
        )

        :telemetry.execute(
          [:railway_agent, :remediation, :failure],
          %{count: 1},
          %{action_type: action.action_type}
        )

        # Send Slack notification with updated action containing failure_reason
        SlackNotifier.send_remediation_update(updated_incident, updated_action, "failed")
    end
  end

  # Format success message for display
  defp format_success_message(response) do
    case response do
      true ->
        "✅ Action completed successfully"

      %{"serviceInstanceRedeploy" => true} ->
        "✅ Service redeployed successfully"

      %{"serviceInstanceUpdate" => true} ->
        "✅ Service scaled successfully"

      %{"deploymentRollback" => %{"id" => id}} ->
        "✅ Rolled back to deployment #{String.slice(id, 0, 8)}..."

      msg when is_binary(msg) ->
        "✅ #{msg}"

      other ->
        "✅ Action completed: #{inspect(other)}"
    end
  end

  # Format failure message for display
  defp format_failure_message(reason) do
    case reason do
      msg when is_binary(msg) ->
        "❌ #{msg}"

      {:error, msg} when is_binary(msg) ->
        "❌ #{msg}"

      "API request failed with status 400" ->
        "❌ Railway API rejected the request (400 Bad Request)"

      "API request failed with status 401" ->
        "❌ Authentication failed - check Railway API token"

      "API request failed with status 403" ->
        "❌ Permission denied - check API token permissions"

      "API request failed with status 404" ->
        "❌ Service or resource not found"

      other ->
        "❌ #{inspect(other)}"
    end
  end

  defp find_previous_successful_deployment(edges) do
    edges
    |> Enum.find(fn %{"node" => node} -> node["status"] == "SUCCESS" end)
    |> case do
      %{"node" => %{"id" => id}} -> id
      _ -> nil
    end
  end
end
