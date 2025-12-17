defmodule RailwayApp.Analysis.LLMRouter do
  @moduledoc """
  Routes LLM requests to configured providers (OpenAI, Anthropic).
  Handles provider selection, retries, and fallback logic.
  """

  require Logger

  @openai_endpoint "https://api.openai.com/v1/chat/completions"
  @anthropic_endpoint "https://api.anthropic.com/v1/messages"
  @default_model_openai "gpt-4o-mini"
  @default_model_anthropic "claude-3-5-sonnet-20241022"

  @doc """
  Analyzes logs to detect incidents and provide recommendations.
  Returns {:ok, analysis} or {:error, reason}.
  """
  def analyze_logs(logs, service_name) do
    prompt = build_analysis_prompt(logs, service_name)

    case select_provider() do
      {:ok, provider} ->
        call_provider(provider, prompt)

      {:error, reason} ->
        Logger.error("No LLM provider available: #{reason}")
        {:error, :no_provider}
    end
  end

  @doc """
  Parses user intent from conversational commands.
  """
  def parse_intent(message, context \\ %{}) do
    prompt = build_intent_prompt(message, context)

    case select_provider() do
      {:ok, provider} ->
        call_provider(provider, prompt)

      {:error, reason} ->
        Logger.error("No LLM provider available: #{reason}")
        {:error, :no_provider}
    end
  end

  @doc """
  Generates remediation recommendations for an incident.
  Takes incident details and returns recommended actions with explanations.
  """
  def get_remediation_recommendation(incident, recent_logs \\ []) do
    prompt = build_remediation_prompt(incident, recent_logs)

    case select_provider() do
      {:ok, provider} ->
        call_provider_for_remediation(provider, prompt)

      {:error, reason} ->
        Logger.error("No LLM provider available: #{reason}")
        {:error, :no_provider}
    end
  end

  # Private Functions

  defp select_provider do
    config = Application.get_env(:railway_app, :llm, [])
    default = config[:default_provider] || "auto"

    cond do
      default == "openai" && config[:openai_api_key] ->
        {:ok, :openai}

      default == "anthropic" && config[:anthropic_api_key] ->
        {:ok, :anthropic}

      default == "auto" && config[:openai_api_key] ->
        {:ok, :openai}

      default == "auto" && config[:anthropic_api_key] ->
        {:ok, :anthropic}

      true ->
        {:error, "No LLM provider configured"}
    end
  end

  defp call_provider(:openai, prompt) do
    config = Application.get_env(:railway_app, :llm, [])
    api_key = config[:openai_api_key]

    body = %{
      model: @default_model_openai,
      messages: [
        %{
          role: "system",
          content:
            "You are an expert DevOps assistant analyzing production kubernetes issues and incidents. Always respond with valid JSON only."
        },
        %{role: "user", content: prompt}
      ],
      temperature: 0.3,
      max_tokens: 1000,
      response_format: %{type: "json_object"}
    }

    case Req.post(@openai_endpoint,
           json: body,
           headers: [{"authorization", "Bearer #{api_key}"}],
           retry: :transient,
           max_retries: 2
         ) do
      {:ok, %{status: 200, body: response}} ->
        extract_openai_response(response)

      {:ok, %{status: status}} ->
        Logger.error("OpenAI API error: status #{status}")
        {:error, :api_error}

      {:error, reason} ->
        Logger.error("OpenAI API request failed: #{inspect(reason)}")
        {:error, :request_failed}
    end
  end

  defp call_provider(:anthropic, prompt) do
    config = Application.get_env(:railway_app, :llm, [])
    api_key = config[:anthropic_api_key]

    body = %{
      model: @default_model_anthropic,
      messages: [
        %{role: "user", content: prompt}
      ],
      system:
        "You are an expert DevOps assistant analyzing production kubernetes issues and incidents.",
      max_tokens: 1000
    }

    case Req.post(@anthropic_endpoint,
           json: body,
           headers: [
             {"x-api-key", api_key},
             {"anthropic-version", "2023-06-01"}
           ],
           retry: :transient,
           max_retries: 2
         ) do
      {:ok, %{status: 200, body: response}} ->
        extract_anthropic_response(response)

      {:ok, %{status: status}} ->
        Logger.error("Anthropic API error: status #{status}")
        {:error, :api_error}

      {:error, reason} ->
        Logger.error("Anthropic API request failed: #{inspect(reason)}")
        {:error, :request_failed}
    end
  end

  defp extract_openai_response(%{"choices" => [%{"message" => %{"content" => content}} | _]}) do
    parse_analysis_response(content)
  end

  defp extract_openai_response(_), do: {:error, :invalid_response}

  defp extract_anthropic_response(%{"content" => [%{"text" => content} | _]}) do
    parse_analysis_response(content)
  end

  defp extract_anthropic_response(_), do: {:error, :invalid_response}

  defp parse_analysis_response(content) do
    # Try to extract and parse JSON from the LLM response
    # LLMs often wrap JSON in text like "Here's my analysis: {...}"
    json_content = extract_json_from_text(content)

    case Jason.decode(json_content) do
      {:ok, parsed} ->
        {:ok,
         %{
           severity: parsed["severity"] || "medium",
           confidence: parsed["confidence"] || 0.5,
           root_cause: parsed["root_cause"] || content,
           recommended_action: parsed["recommended_action"] || "manual_fix",
           reasoning: parsed["reasoning"] || content
         }}

      {:error, _} ->
        Logger.warning(
          "Failed to parse LLM response as JSON: #{String.slice(content, 0, 200)}...",
          %{}
        )

        # Fallback: extract key information from unstructured text
        {:ok,
         %{
           severity: extract_severity(content),
           confidence: 0.6,
           root_cause: content,
           recommended_action: extract_action(content),
           reasoning: content
         }}
    end
  end

  # Extract JSON object from text that may contain surrounding prose
  defp extract_json_from_text(text) do
    # Try to find JSON object pattern in the text
    case Regex.run(~r/\{[\s\S]*\}/, text) do
      [json] -> json
      nil -> text
    end
  end

  defp build_analysis_prompt(logs, service_name) do
    log_text =
      logs
      |> Enum.map(fn log -> "#{log[:timestamp]} [#{log[:level]}] #{log[:message]}" end)
      |> Enum.join("\n")

    """
    Analyze the following logs from service "#{service_name}" and identify any production incidents that require attention.

    Logs:
    #{log_text}

    Incident Detection Guidelines:
    - ERROR logs with failures, exceptions, or service degradation = HIGH confidence (0.8+)
    - WARNING logs with timeouts, high resource usage, or rate limits = MEDIUM confidence (0.7+)
    - Repeated warnings or patterns indicating degradation = HIGH confidence (0.8+)
    - Normal operational logs (health checks, completed jobs) = LOW confidence (<0.5)
    - If logs indicate actual problems requiring action, set confidence >= 0.7

    IMPORTANT: Respond with ONLY a valid JSON object, no additional text or explanation before or after.

    JSON Response Format:
    {"severity": "critical|high|medium|low", "confidence": 0.0-1.0, "root_cause": "Brief description of the root cause", "recommended_action": "restart|redeploy|scale_memory|scale_replicas|rollback|stop|manual_fix|none", "reasoning": "Explanation of your analysis"}
    """
  end

  defp build_intent_prompt(message, _context) do
    """
    Parse the following user command and extract the intent and parameters.

    User message: "#{message}"

    Provide your response in JSON format:
    {
      "intent": "restart|scale|rollback|status|logs|deployments|help",
      "service": "service_name",
      "parameters": {},
      "confidence": 0.0-1.0
    }
    """
  end

  defp extract_severity(text) do
    text_lower = String.downcase(text)

    cond do
      String.contains?(text_lower, ["critical", "fatal", "crash", "down"]) -> "critical"
      String.contains?(text_lower, ["error", "failed", "failure"]) -> "high"
      String.contains?(text_lower, ["warning", "warn"]) -> "medium"
      true -> "low"
    end
  end

  defp extract_action(text) do
    text_lower = String.downcase(text)

    cond do
      String.contains?(text_lower, ["restart", "reboot"]) -> "restart"
      String.contains?(text_lower, ["memory", "oom", "out of memory"]) -> "scale_memory"
      String.contains?(text_lower, ["scale", "replicas"]) -> "scale_replicas"
      String.contains?(text_lower, ["rollback", "revert"]) -> "rollback"
      true -> "manual_fix"
    end
  end

  defp build_remediation_prompt(incident, recent_logs) do
    log_text =
      recent_logs
      |> Enum.take(50)
      |> Enum.map(fn log ->
        timestamp = log[:timestamp] || log["timestamp"] || ""
        level = log[:level] || log["level"] || "info"
        message = log[:message] || log["message"] || ""
        "#{timestamp} [#{level}] #{message}"
      end)
      |> Enum.join("\n")

    """
    You are an expert DevOps engineer. Analyze this incident and recommend the best remediation action.

    INCIDENT DETAILS:
    - Service: #{incident.service_name || "Unknown"}
    - Service ID: #{incident.service_id}
    - Severity: #{incident.severity}
    - Root Cause: #{incident.root_cause || "Not determined"}
    - Current Recommended Action: #{incident.recommended_action || "none"}
    - Detected At: #{incident.detected_at}

    RECENT LOGS:
    #{if log_text != "", do: log_text, else: "No recent logs available"}

    AVAILABLE ACTIONS:
    1. restart - Restart the current deployment (good for memory leaks, stuck processes)
    2. redeploy - Fresh deployment from source (good for corrupted state)
    3. scale_memory - Increase memory allocation (good for OOM errors)
    4. scale_replicas - Add more replicas (good for high load)
    5. rollback - Revert to previous deployment (good for bad deploys)
    6. stop - Stop the service (emergency only)
    7. manual_fix - Requires manual intervention

    Provide your recommendation in JSON format:
    {
      "recommended_action": "restart|redeploy|scale_memory|scale_replicas|rollback|stop|manual_fix",
      "confidence": 0.0-1.0,
      "explanation": "Clear explanation of why this action is recommended",
      "risk_level": "low|medium|high",
      "alternative_action": "Optional alternative action if first doesn't work",
      "estimated_recovery_time": "Estimated time to recovery (e.g., '2-5 minutes')"
    }
    """
  end

  defp call_provider_for_remediation(:openai, prompt) do
    config = Application.get_env(:railway_app, :llm, [])
    api_key = config[:openai_api_key]

    body = %{
      model: @default_model_openai,
      messages: [
        %{
          role: "system",
          content:
            "You are an expert DevOps assistant specializing in incident remediation for Railway.app services. Always respond with valid JSON."
        },
        %{role: "user", content: prompt}
      ],
      temperature: 0.2,
      max_tokens: 800
    }

    case Req.post(@openai_endpoint,
           json: body,
           headers: [{"authorization", "Bearer #{api_key}"}],
           retry: :transient,
           max_retries: 2
         ) do
      {:ok, %{status: 200, body: response}} ->
        extract_remediation_response(response)

      {:ok, %{status: status}} ->
        Logger.error("OpenAI API error: status #{status}")
        {:error, :api_error}

      {:error, reason} ->
        Logger.error("OpenAI API request failed: #{inspect(reason)}")
        {:error, :request_failed}
    end
  end

  defp call_provider_for_remediation(:anthropic, prompt) do
    config = Application.get_env(:railway_app, :llm, [])
    api_key = config[:anthropic_api_key]

    body = %{
      model: @default_model_anthropic,
      messages: [
        %{role: "user", content: prompt}
      ],
      system:
        "You are an expert DevOps assistant specializing in incident remediation for Railway.app services. Always respond with valid JSON.",
      max_tokens: 800
    }

    case Req.post(@anthropic_endpoint,
           json: body,
           headers: [
             {"x-api-key", api_key},
             {"anthropic-version", "2023-06-01"}
           ],
           retry: :transient,
           max_retries: 2
         ) do
      {:ok, %{status: 200, body: response}} ->
        extract_remediation_response_anthropic(response)

      {:ok, %{status: status}} ->
        Logger.error("Anthropic API error: status #{status}")
        {:error, :api_error}

      {:error, reason} ->
        Logger.error("Anthropic API request failed: #{inspect(reason)}")
        {:error, :request_failed}
    end
  end

  defp extract_remediation_response(%{"choices" => [%{"message" => %{"content" => content}} | _]}) do
    parse_remediation_json(content)
  end

  defp extract_remediation_response(_), do: {:error, :invalid_response}

  defp extract_remediation_response_anthropic(%{"content" => [%{"text" => content} | _]}) do
    parse_remediation_json(content)
  end

  defp extract_remediation_response_anthropic(_), do: {:error, :invalid_response}

  defp parse_remediation_json(content) do
    # Try to extract JSON from the content (LLM might include extra text)
    json_content =
      case Regex.run(~r/\{[\s\S]*\}/, content) do
        [json] -> json
        _ -> content
      end

    case Jason.decode(json_content) do
      {:ok, parsed} ->
        {:ok,
         %{
           recommended_action: parsed["recommended_action"] || "manual_fix",
           confidence: parsed["confidence"] || 0.5,
           explanation: parsed["explanation"] || "No explanation provided",
           risk_level: parsed["risk_level"] || "medium",
           alternative_action: parsed["alternative_action"],
           estimated_recovery_time: parsed["estimated_recovery_time"] || "Unknown"
         }}

      {:error, _} ->
        # Fallback: try to extract action from text
        {:ok,
         %{
           recommended_action: extract_action(content),
           confidence: 0.5,
           explanation: content,
           risk_level: "medium",
           alternative_action: nil,
           estimated_recovery_time: "Unknown"
         }}
    end
  end
end
