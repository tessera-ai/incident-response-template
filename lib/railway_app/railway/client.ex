defmodule RailwayApp.Railway.Client do
  @moduledoc """
  HTTP client for Railway GraphQL API using Req.
  Handles queries and mutations with retry logic and rate limiting.
  """

  require Logger

  @graphql_endpoint "https://backboard.railway.app/graphql/v2"
  @max_retries 3
  @base_backoff 1000

  @doc """
  Executes a GraphQL query against the Railway API.
  """
  def query(query_string, variables \\ %{}) do
    config = Application.get_env(:railway_app, :railway, [])
    token = config[:api_token]

    if !token do
      {:error, "Railway API token not configured"}
    else
      body = %{
        query: query_string,
        variables: variables
      }

      request(:post, graphql_url(), body, token)
    end
  end

  @doc """
  Restarts/Redeploys a Railway service instance.
  Requires both service_id and environment_id.
  """
  def restart_service(service_id, environment_id) do
    mutation = """
    mutation RedeployService($serviceId: String!, $environmentId: String!) {
      serviceInstanceRedeploy(serviceId: $serviceId, environmentId: $environmentId)
    }
    """

    query(mutation, %{serviceId: service_id, environmentId: environment_id})
  end

  @doc """
  Scales service replicas. Requires both service_id and environment_id.
  Note: Memory scaling is not directly supported via Railway API mutations.
  For memory issues, consider restarting or redeploying instead.
  """
  def scale_memory(service_id, environment_id, _memory_mb \\ nil) do
    # Memory scaling is not a direct Railway API feature
    # Instead, we redeploy the service which can help with memory issues
    Logger.warning(
      "Memory scaling not directly supported by Railway API. Using redeploy instead.",
      %{}
    )

    restart_service(service_id, environment_id)
  end

  @doc """
  Scales service replicas.
  """
  def scale_replicas(service_id, environment_id, replica_count) do
    mutation = """
    mutation ScaleReplicas($serviceId: String!, $environmentId: String, $replicas: Int!) {
      serviceInstanceUpdate(serviceId: $serviceId, environmentId: $environmentId, input: { numReplicas: $replicas })
    }
    """

    query(mutation, %{
      serviceId: service_id,
      environmentId: environment_id,
      replicas: replica_count
    })
  end

  @doc """
  Rolls back service to previous deployment.
  """
  def rollback_service(_service_id, deployment_id) do
    mutation = """
    mutation RollbackService($deploymentId: String!) {
      deploymentRollback(deploymentId: $deploymentId) {
        id
      }
    }
    """

    query(mutation, %{deploymentId: deployment_id})
  end

  @doc """
  Fetches recent deployments for a service.
  """
  def get_deployments(service_id, limit \\ 10) do
    query_string = """
    query GetDeployments($serviceId: String!, $limit: Int!) {
      service(id: $serviceId) {
        id
        name
        deployments(first: $limit) {
          edges {
            node {
              id
              status
              createdAt
            }
          }
        }
      }
    }
    """

    query(query_string, %{serviceId: service_id, limit: limit})
  end

  @doc """
  Fetches recent deployments for a service via the project context.
  This is a fallback for when the direct service(id: ...) query is unauthorized.
  """
  def get_deployments_via_project(project_id, service_id, limit \\ 10) do
    query_string = """
    query GetProjectDeployments($projectId: String!, $limit: Int!) {
      project(id: $projectId) {
        services {
          id
          name
          deployments(first: $limit) {
            edges {
              node {
                id
                status
                createdAt
              }
            }
          }
        }
      }
    }
    """

    case query(query_string, %{projectId: project_id, limit: limit}) do
      {:ok, %{"project" => %{"services" => services}}} when is_list(services) ->
        case Enum.find(services, fn s -> s["id"] == service_id end) do
          nil -> {:error, :service_not_found}
          service -> {:ok, %{"service" => service}}
        end

      {:ok, _} ->
        {:error, :invalid_response}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Fetches service state and configuration information.
  """
  def get_service_state(service_id) do
    query_string = """
    query GetServiceState($serviceId: String!) {
      service(id: $serviceId) {
        id
        name
        status
        timestamp
        environmentId
        deploymentId
        metrics {
          cpu
          memory
          restarts
        }
      }
    }
    """

    query(query_string, %{serviceId: service_id})
  end

  @doc """
  Fetches project services for monitoring.
  """
  def get_project_services(project_id, environment_id \\ nil) do
    query_string = """
    query GetProjectServices($projectId: String!, $environmentId: String) {
      project(id: $projectId) {
        services {
          id
          name
          status
          environment {
            id
            name
          }
          deployment {
            id
            status
            createdAt
          }
        }
      }
    }
    """

    variables = %{projectId: project_id}

    variables =
      if environment_id, do: Map.put(variables, :environmentId, environment_id), else: variables

    query(query_string, variables)
  end

  @doc """
  Validates API token permissions by making a simple query.
  """
  def validate_token do
    query_string = """
    query ValidateToken {
      project {
        id
        name
      }
    }
    """

    case query(query_string) do
      {:ok, %{"project" => _project}} -> {:ok, :valid}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Fetches service logs metadata (not actual logs, used for validation).
  """
  def get_service_logs_metadata(service_id, limit \\ 10) do
    query_string = """
    query GetServiceLogs($serviceId: String!, $limit: Int!) {
      service(id: $serviceId) {
        logs(first: $limit) {
          edges {
            node {
              id
              timestamp
              level
            }
          }
        }
      }
    }
    """

    query(query_string, %{serviceId: service_id, limit: limit})
  end

  @doc """
  Checks API rate limit status.
  """
  def check_rate_limit do
    query_string = """
    query CheckRateLimit {
      rateLimit {
        remaining
        resetAt
      }
    }
    """

    query(query_string)
  end

  @doc """
  Fetches the latest deployment ID for a given project, environment, and service.

  This is used to get the deployment ID needed for log subscriptions when you only
  have project/environment/service IDs from configuration.

  Returns `{:ok, deployment_id}` or `{:error, reason}`.
  """
  def get_latest_deployment_id(project_id, environment_id, service_id) do
    query_string = """
    query GetLatestDeployment($serviceId: String!) {
      service(id: $serviceId) {
        id
        serviceInstances {
          edges {
            node {
              environmentId
              latestDeployment {
                id
                status
                createdAt
              }
            }
          }
        }
      }
    }
    """

    variables = %{
      serviceId: service_id
    }

    case query(query_string, variables) do
      {:ok, data} ->
        parse_latest_deployment(data, environment_id, service_id, project_id)

      {:error, reason} ->
        Logger.error(
          "Failed to fetch deployment for project #{project_id}, env #{environment_id}, service #{service_id}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp parse_latest_deployment(data, environment_id, service_id, _project_id) do
    with %{"service" => %{"serviceInstances" => %{"edges" => instance_edges}}} <- data,
         instance when not is_nil(instance) <-
           find_instance_by_environment(instance_edges, environment_id),
         %{"latestDeployment" => deployment} when not is_nil(deployment) <- instance,
         %{"id" => deployment_id} <- deployment do
      Logger.info(
        "Found latest deployment #{deployment_id} (status: #{deployment["status"]}) for service #{service_id} in environment #{environment_id}"
      )

      {:ok, deployment_id}
    else
      nil ->
        Logger.warning(
          "No deployment found for service #{service_id} in environment #{environment_id}",
          %{}
        )

        {:error, :no_deployment_found}

      %{"latestDeployment" => nil} ->
        Logger.warning(
          "Service #{service_id} in environment #{environment_id} has no deployments yet",
          %{}
        )

        {:error, :no_deployment_found}

      other ->
        Logger.warning("Unexpected response structure: #{inspect(other)}", %{})
        {:error, :invalid_response}
    end
  end

  defp find_instance_by_environment(edges, environment_id) do
    Enum.find_value(edges, fn
      %{"node" => %{"environmentId" => ^environment_id} = node} -> node
      _ -> nil
    end)
  end

  # =============================================================================
  # Deployment Operations
  # =============================================================================

  @doc """
  Restarts a deployment by ID.
  """
  def restart_deployment(deployment_id) do
    mutation = """
    mutation RestartDeployment($id: String!) {
      deploymentRestart(id: $id)
    }
    """

    query(mutation, %{id: deployment_id})
  end

  @doc """
  Redeploys a deployment. Optionally use the previous image tag.
  """
  def redeploy_deployment(deployment_id, opts \\ []) do
    use_previous_image = Keyword.get(opts, :use_previous_image, false)

    mutation = """
    mutation RedeployDeployment($id: String!, $usePreviousImageTag: Boolean) {
      deploymentRedeploy(id: $id, usePreviousImageTag: $usePreviousImageTag) {
        id
        status
        createdAt
      }
    }
    """

    query(mutation, %{id: deployment_id, usePreviousImageTag: use_previous_image})
  end

  @doc """
  Stops a deployment.
  """
  def stop_deployment(deployment_id) do
    mutation = """
    mutation StopDeployment($id: String!) {
      deploymentStop(id: $id)
    }
    """

    query(mutation, %{id: deployment_id})
  end

  @doc """
  Cancels a deployment.
  """
  def cancel_deployment(deployment_id) do
    mutation = """
    mutation CancelDeployment($id: String!) {
      deploymentCancel(id: $id)
    }
    """

    query(mutation, %{id: deployment_id})
  end

  @doc """
  Rolls back to a specific deployment.
  """
  def rollback_deployment(deployment_id) do
    mutation = """
    mutation RollbackDeployment($id: String!) {
      deploymentRollback(id: $id)
    }
    """

    query(mutation, %{id: deployment_id})
  end

  # =============================================================================
  # Service Instance Operations
  # =============================================================================

  @doc """
  Fetches a service instance by environment and service ID.
  Returns detailed information about the service instance including deployment status.
  """
  def get_service_instance(environment_id, service_id) do
    query_string = """
    query GetServiceInstance($environmentId: String!, $serviceId: String!) {
      serviceInstance(environmentId: $environmentId, serviceId: $serviceId) {
        id
        environmentId
        serviceId
        serviceName
        startCommand
        buildCommand
        healthcheckPath
        numReplicas
        region
        restartPolicyType
        restartPolicyMaxRetries
        sleepApplication
        latestDeployment {
          id
          status
          createdAt
          staticUrl
          url
        }
        domains {
          serviceDomains {
            domain
          }
          customDomains {
            domain
            status {
              certificateStatus
            }
          }
        }
      }
    }
    """

    query(query_string, %{environmentId: environment_id, serviceId: service_id})
  end

  @doc """
  Updates a service instance configuration.

  Options:
  - `:num_replicas` - Number of replicas
  - `:start_command` - Start command
  - `:healthcheck_path` - Healthcheck path
  - `:restart_policy_type` - Restart policy type (ON_FAILURE, ALWAYS, NEVER)
  - `:restart_policy_max_retries` - Max restart retries
  """
  def update_service_instance(environment_id, service_id, opts) do
    input =
      opts
      |> Enum.reduce(%{}, fn
        {:num_replicas, v}, acc -> Map.put(acc, :numReplicas, v)
        {:start_command, v}, acc -> Map.put(acc, :startCommand, v)
        {:healthcheck_path, v}, acc -> Map.put(acc, :healthcheckPath, v)
        {:restart_policy_type, v}, acc -> Map.put(acc, :restartPolicyType, v)
        {:restart_policy_max_retries, v}, acc -> Map.put(acc, :restartPolicyMaxRetries, v)
        _, acc -> acc
      end)

    mutation = """
    mutation UpdateServiceInstance($environmentId: String!, $serviceId: String!, $input: ServiceInstanceUpdateInput!) {
      serviceInstanceUpdate(environmentId: $environmentId, serviceId: $serviceId, input: $input)
    }
    """

    query(mutation, %{environmentId: environment_id, serviceId: service_id, input: input})
  end

  @doc """
  Updates resource limits for a service instance.

  Options:
  - `:memory_mb` - Memory limit in MB
  - `:cpu_count` - CPU count limit
  """
  def update_service_limits(environment_id, service_id, opts) do
    input =
      %{
        environmentId: environment_id,
        serviceId: service_id
      }
      |> then(fn m ->
        if memory = Keyword.get(opts, :memory_mb), do: Map.put(m, :memoryMB, memory), else: m
      end)
      |> then(fn m ->
        if cpu = Keyword.get(opts, :cpu_count), do: Map.put(m, :cpuCount, cpu), else: m
      end)

    mutation = """
    mutation UpdateServiceLimits($input: ServiceInstanceLimitsUpdateInput!) {
      serviceInstanceLimitsUpdate(input: $input)
    }
    """

    query(mutation, %{input: input})
  end

  @doc """
  Triggers a new deployment for a service instance.
  Optionally specify a commit SHA to deploy.
  """
  def deploy_service_instance(environment_id, service_id, opts \\ []) do
    commit_sha = Keyword.get(opts, :commit_sha)

    mutation = """
    mutation DeployServiceInstance($environmentId: String!, $serviceId: String!, $commitSha: String) {
      serviceInstanceDeployV2(environmentId: $environmentId, serviceId: $serviceId, commitSha: $commitSha)
    }
    """

    query(mutation, %{
      environmentId: environment_id,
      serviceId: service_id,
      commitSha: commit_sha
    })
  end

  # =============================================================================
  # Query Operations
  # =============================================================================

  @doc """
  Fetches a single deployment by ID with detailed information.
  """
  def get_deployment(deployment_id) do
    query_string = """
    query GetDeployment($id: String!) {
      deployment(id: $id) {
        id
        status
        createdAt
        updatedAt
        projectId
        serviceId
        environmentId
        staticUrl
        url
        canRedeploy
        canRollback
        meta {
          branch
          commitHash
          commitMessage
          commitAuthor
        }
      }
    }
    """

    query(query_string, %{id: deployment_id})
  end

  @doc """
  Fetches deployment logs (one-time query, not streaming).

  Options:
  - `:limit` - Maximum number of log entries (default: 100)
  - `:filter` - Filter string for logs
  - `:start_date` - Start date for log range
  - `:end_date` - End date for log range
  """
  def get_deployment_logs(deployment_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    filter = Keyword.get(opts, :filter)
    start_date = Keyword.get(opts, :start_date)
    end_date = Keyword.get(opts, :end_date)

    query_string = """
    query GetDeploymentLogs($deploymentId: String!, $limit: Int, $filter: String, $startDate: DateTime, $endDate: DateTime) {
      deploymentLogs(deploymentId: $deploymentId, limit: $limit, filter: $filter, startDate: $startDate, endDate: $endDate) {
        message
        timestamp
        severity
      }
    }
    """

    variables =
      %{deploymentId: deployment_id, limit: limit}
      |> then(fn v -> if filter, do: Map.put(v, :filter, filter), else: v end)
      |> then(fn v -> if start_date, do: Map.put(v, :startDate, start_date), else: v end)
      |> then(fn v -> if end_date, do: Map.put(v, :endDate, end_date), else: v end)

    query(query_string, variables)
  end

  @doc """
  Fetches metrics for a service.

  Options:
  - `:start_date` - Start date for metrics range (required)
  - `:end_date` - End date for metrics range (default: now)
  - `:sample_rate_seconds` - Sample rate in seconds (default: 60)
  - `:measurements` - List of measurements to fetch (cpu, memory, network, etc.)
  """
  def get_metrics(project_id, service_id, environment_id, opts \\ []) do
    start_date = Keyword.fetch!(opts, :start_date)
    end_date = Keyword.get(opts, :end_date, DateTime.utc_now() |> DateTime.to_iso8601())
    sample_rate = Keyword.get(opts, :sample_rate_seconds, 60)

    query_string = """
    query GetMetrics($projectId: String!, $serviceId: String!, $environmentId: String!, $startDate: DateTime!, $endDate: DateTime!, $sampleRateSeconds: Int) {
      metrics(
        projectId: $projectId
        serviceId: $serviceId
        environmentId: $environmentId
        startDate: $startDate
        endDate: $endDate
        sampleRateSeconds: $sampleRateSeconds
        measurements: [CPU_USAGE, MEMORY_USAGE_MB, NETWORK_RX_GB, NETWORK_TX_GB]
      ) {
        measurement
        tags
        values {
          ts
          value
        }
      }
    }
    """

    query(query_string, %{
      projectId: project_id,
      serviceId: service_id,
      environmentId: environment_id,
      startDate: start_date,
      endDate: end_date,
      sampleRateSeconds: sample_rate
    })
  end

  @doc """
  Fetches variables for a service in an environment.
  """
  def get_variables(project_id, environment_id, service_id) do
    query_string = """
    query GetVariables($projectId: String!, $environmentId: String!, $serviceId: String!) {
      variables(projectId: $projectId, environmentId: $environmentId, serviceId: $serviceId)
    }
    """

    query(query_string, %{
      projectId: project_id,
      environmentId: environment_id,
      serviceId: service_id
    })
  end

  @doc """
  Upserts (creates or updates) an environment variable.
  """
  def upsert_variable(project_id, environment_id, service_id, key, value) do
    mutation = """
    mutation UpsertVariable($input: VariableUpsertInput!) {
      variableUpsert(input: $input)
    }
    """

    input = %{
      projectId: project_id,
      environmentId: environment_id,
      serviceId: service_id,
      name: key,
      value: value
    }

    query(mutation, %{input: input})
  end

  # Private functions

  defp graphql_url do
    config = Application.get_env(:railway_app, :railway, [])
    config[:graphql_endpoint] || @graphql_endpoint
  end

  defp request(method, url, body, token, retry_count \\ 0) do
    headers = [
      {"authorization", "Bearer #{token}"},
      {"content-type", "application/json"}
    ]

    case Req.request(
           method: method,
           url: url,
           json: body,
           headers: headers,
           retry: :transient,
           max_retries: @max_retries,
           retry_delay: fn attempt -> @base_backoff * :math.pow(2, attempt - 1) end
         ) do
      {:ok, %{status: status, body: response_body}} when status in 200..299 ->
        case response_body do
          %{"data" => data, "errors" => nil} -> {:ok, data}
          %{"data" => data} when not is_nil(data) -> {:ok, data}
          %{"errors" => errors} -> {:error, format_graphql_errors(errors)}
          _ -> {:error, "Unexpected response format"}
        end

      {:ok, %{status: 429, headers: headers}} ->
        if retry_count < @max_retries do
          backoff =
            parse_retry_after(headers, (@base_backoff * :math.pow(2, retry_count)) |> trunc())

          Logger.warning("Rate limited by Railway API, retrying in #{backoff}ms", %{})
          Process.sleep(backoff)
          request(method, url, body, token, retry_count + 1)
        else
          {:error, "Rate limit exceeded after #{@max_retries} retries"}
        end

      {:ok, %{status: status, body: body}} ->
        Logger.error("Railway API request failed with status #{status}: #{inspect(body)}")
        {:error, "API request failed with status #{status}"}

      {:error, reason} ->
        Logger.error("Railway API request error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp format_graphql_errors(errors) when is_list(errors) do
    errors
    |> Enum.map(fn error -> error["message"] || inspect(error) end)
    |> Enum.join(", ")
  end

  defp format_graphql_errors(error), do: inspect(error)

  defp parse_retry_after(headers, default_backoff) do
    case List.keyfind(headers, "retry-after", 0) do
      {_, value} ->
        case Float.parse(value) do
          {seconds, _} -> trunc(seconds * 1000)
          :error -> default_backoff
        end

      nil ->
        default_backoff
    end
  end
end
