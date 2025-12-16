defmodule RailwayApp.Alerts.SlackNotifier do
  @moduledoc """
  Sends notifications to Slack for incidents and remediation updates.
  """

  require Logger

  @slack_api_url "https://slack.com/api"

  @doc """
  Sends an incident alert to Slack.
  """
  def send_incident_alert(incident) do
    config = Application.get_env(:railway_app, :slack, [])
    token = config[:bot_token]
    channel_id = config[:channel_id]

    if !(token && channel_id) do
      Logger.warning("Slack not configured, skipping notification", %{})
      {:error, :not_configured}
    else
      Logger.info(
        "[Slack] Preparing INCIDENT ALERT: incident_id=#{incident.id} service=#{incident.service_name} severity=#{incident.severity} action=#{incident.recommended_action}"
      )

      blocks = build_incident_blocks(incident)

      payload = %{
        channel: channel_id,
        text: "🚨 New Incident: #{incident.service_name}",
        blocks: blocks
      }

      post_message(token, payload)
    end
  end

  @doc """
  Sends a remediation update to Slack.
  """
  def send_remediation_update(incident, action, status) do
    config = Application.get_env(:railway_app, :slack, [])
    token = config[:bot_token]
    channel_id = config[:channel_id]

    if !(token && channel_id) do
      Logger.warning("Slack not configured, skipping notification", %{})
      {:error, :not_configured}
    else
      Logger.info(
        "[Slack] Preparing REMEDIATION UPDATE: incident_id=#{incident.id} action=#{action.action_type} status=#{status} result=#{action.result_message || action.failure_reason || "pending"}"
      )

      blocks = build_remediation_blocks(incident, action, status)

      payload = %{
        channel: channel_id,
        text: "Remediation Update: #{incident.service_name}",
        blocks: blocks
      }

      post_message(token, payload)
    end
  end

  @doc """
  Sends a conversational message to a thread.
  """
  def send_message(channel_id, text, thread_ts \\ nil) do
    config = Application.get_env(:railway_app, :slack, [])
    token = config[:bot_token]

    if !token do
      Logger.warning("Slack not configured, skipping message", %{})
      {:error, :not_configured}
    else
      payload = %{
        channel: channel_id,
        text: text,
        thread_ts: thread_ts
      }

      post_message(token, payload)
    end
  end

  @doc """
  Sends an AI recommendation message with Confirm/Cancel buttons.
  """
  def send_recommendation_message(channel_id, incident, recommendation, thread_ts \\ nil) do
    config = Application.get_env(:railway_app, :slack, [])
    token = config[:bot_token]

    if !token do
      Logger.warning("Slack not configured, skipping recommendation message", %{})
      {:error, :not_configured}
    else
      Logger.info(
        "[Slack] Preparing AI RECOMMENDATION: incident_id=#{incident.id} action=#{recommendation.recommended_action} confidence=#{recommendation.confidence} risk=#{recommendation.risk_level}"
      )

      blocks = build_recommendation_blocks(incident, recommendation)

      payload = %{
        channel: channel_id,
        text: "🤖 AI Recommendation for #{incident.service_name}",
        blocks: blocks,
        thread_ts: thread_ts
      }

      post_message(token, payload)
    end
  end

  @doc """
  Sends a fallback recommendation message when AI analysis fails.
  """
  def send_fallback_recommendation_message(channel_id, incident, thread_ts \\ nil) do
    config = Application.get_env(:railway_app, :slack, [])
    token = config[:bot_token]

    if !token do
      Logger.warning("Slack not configured, skipping fallback message", %{})
      {:error, :not_configured}
    else
      blocks = build_fallback_recommendation_blocks(incident)

      payload = %{
        channel: channel_id,
        text: "Fallback Recommendation for #{incident.service_name}",
        blocks: blocks,
        thread_ts: thread_ts
      }

      post_message(token, payload)
    end
  end

  @doc """
  Sends an ignore confirmation message with incident summary.
  """
  def send_ignore_confirmation(channel_id, incident, thread_ts \\ nil) do
    config = Application.get_env(:railway_app, :slack, [])
    token = config[:bot_token]

    if !token do
      Logger.warning("Slack not configured, skipping ignore confirmation", %{})
      {:error, :not_configured}
    else
      blocks = build_ignore_confirmation_blocks(incident)

      payload = %{
        channel: channel_id,
        text: "Incident Ignored: #{incident.service_name}",
        blocks: blocks,
        thread_ts: thread_ts
      }

      post_message(token, payload)
    end
  end

  @doc """
  Updates an existing Slack message.
  """
  def update_message(channel_id, message_ts, blocks) do
    config = Application.get_env(:railway_app, :slack, [])
    token = config[:bot_token]

    if !token do
      Logger.warning("Slack not configured, skipping message update", %{})
      {:error, :not_configured}
    else
      headers = [
        {"authorization", "Bearer #{token}"},
        {"content-type", "application/json"}
      ]

      payload = %{
        channel: channel_id,
        ts: message_ts,
        blocks: blocks
      }

      case Req.post("#{@slack_api_url}/chat.update",
             json: payload,
             headers: headers,
             retry: :transient,
             max_retries: 2
           ) do
        {:ok, %{status: 200, body: %{"ok" => true} = response}} ->
          {:ok, response}

        {:ok, %{status: 200, body: %{"ok" => false, "error" => error}}} ->
          Logger.error("Slack API error updating message: #{error}")
          {:error, error}

        {:ok, %{status: status}} ->
          Logger.error("Slack API returned status #{status}")
          {:error, :api_error}

        {:error, reason} ->
          Logger.error("Failed to update Slack message: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  # Private Functions

  defp post_message(token, payload) do
    headers = [
      {"authorization", "Bearer #{token}"},
      {"content-type", "application/json"}
    ]

    # Log the message being sent for telemetry
    channel = payload[:channel] || payload["channel"]
    text = payload[:text] || payload["text"]
    thread_ts = payload[:thread_ts] || payload["thread_ts"]

    Logger.info(
      "[Slack] Sending message to channel=#{channel} thread=#{thread_ts || "main"}: #{text}"
    )

    start_time = System.monotonic_time()

    result =
      case Req.post("#{@slack_api_url}/chat.postMessage",
             json: payload,
             headers: headers,
             retry: :transient,
             max_retries: 2
           ) do
        {:ok, %{status: 200, body: %{"ok" => true} = response}} ->
          message_ts = response["ts"]

          Logger.info(
            "[Slack] Message sent successfully: channel=#{channel} ts=#{message_ts} text=\"#{String.slice(text, 0, 100)}...\""
          )

          {:ok, response}

        {:ok, %{status: 200, body: %{"ok" => false, "error" => error}}} ->
          Logger.error("[Slack] API error: #{error} for message: #{text}")
          {:error, error}

        {:ok, %{status: status}} ->
          Logger.error("[Slack] API returned status #{status} for message: #{text}")
          {:error, :api_error}

        {:error, reason} ->
          Logger.error("[Slack] Failed to send message: #{inspect(reason)}")
          {:error, reason}
      end

    # Record telemetry
    duration = System.monotonic_time() - start_time

    :telemetry.execute(
      [:railway_agent, :slack, :message_sent],
      %{duration: duration, count: 1},
      %{
        channel: channel,
        success: match?({:ok, _}, result),
        has_thread: thread_ts != nil
      }
    )

    result
  end

  def build_incident_blocks(incident) do
    severity_emoji =
      case incident.severity do
        "critical" -> "🔴"
        "high" -> "🟠"
        "medium" -> "🟡"
        "low" -> "🟢"
        _ -> "⚪"
      end

    action_buttons = [
      %{
        type: "section",
        text: %{
          type: "mrkdwn",
          text: "*Need to discuss this incident?*"
        }
      },
      %{
        type: "actions",
        elements: [
          %{
            type: "button",
            text: %{type: "plain_text", text: "Start Chat"},
            style: "primary",
            action_id: "start_chat",
            value: "start_chat:#{incident.id}"
          }
        ]
      }
    ]

    [
      %{
        type: "header",
        text: %{
          type: "plain_text",
          text:
            "#{severity_emoji} #{incident.service_name} - #{String.capitalize(incident.severity)} Incident"
        }
      },
      %{
        type: "section",
        fields: [
          %{type: "mrkdwn", text: "*Service:*\n#{incident.service_name}"},
          %{type: "mrkdwn", text: "*Severity:*\n#{incident.severity}"},
          %{type: "mrkdwn", text: "*Detected:*\n#{format_timestamp(incident.detected_at)}"},
          %{
            type: "mrkdwn",
            text:
              "*Confidence:*\n#{if incident.confidence, do: "#{trunc(incident.confidence * 100)}%", else: "N/A"}"
          }
        ]
      },
      %{
        type: "section",
        text: %{
          type: "mrkdwn",
          text: "*Root Cause:*\n#{incident.root_cause || "Analysis pending..."}"
        }
      },
      %{
        type: "section",
        text: %{
          type: "mrkdwn",
          text: "*Recommended Action:*\n#{format_action(incident.recommended_action)}"
        }
      }
    ] ++ action_buttons
  end

  def build_remediation_blocks(incident, action, status) do
    status_emoji =
      case status do
        "succeeded" -> "✅"
        "failed" -> "❌"
        "in_progress" -> "⏳"
        _ -> "ℹ️"
      end

    [
      %{
        type: "section",
        text: %{
          type: "mrkdwn",
          text:
            "#{status_emoji} *Remediation Update*\n*Service:* #{incident.service_name}\n*Action:* #{action.action_type}\n*Status:* #{status}"
        }
      },
      %{
        type: "section",
        text: %{
          type: "mrkdwn",
          text: "*Result:*\n#{action.result_message || action.failure_reason || "Processing..."}"
        }
      }
    ]
  end

  def format_action(action) do
    case action do
      "restart" -> "🔄 Restart service"
      "redeploy" -> "🚀 Redeploy service"
      "scale_memory" -> "📈 Scale memory"
      "scale_replicas" -> "📊 Scale replicas"
      "rollback" -> "⏪ Rollback deployment"
      "stop" -> "🛑 Stop service"
      "manual_fix" -> "👨‍💻 Manual intervention required"
      "none" -> "ℹ️ No action needed"
      _ -> action
    end
  end

  def format_timestamp(datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_string()
  end

  defp build_recommendation_blocks(incident, recommendation) do
    risk_emoji =
      case recommendation.risk_level do
        "low" -> "🟢"
        "medium" -> "🟡"
        "high" -> "🔴"
        _ -> "⚪"
      end

    confidence_pct = trunc((recommendation.confidence || 0.5) * 100)

    [
      %{
        type: "header",
        text: %{
          type: "plain_text",
          text: "🤖 AI Remediation Recommendation"
        }
      },
      %{
        type: "section",
        text: %{
          type: "mrkdwn",
          text: "*Service:* #{incident.service_name}\n*Incident ID:* `#{incident.id}`"
        }
      },
      %{type: "divider"},
      %{
        type: "section",
        text: %{
          type: "mrkdwn",
          text: "*Recommended Action:* #{format_action(recommendation.recommended_action)}"
        }
      },
      %{
        type: "section",
        fields: [
          %{type: "mrkdwn", text: "*Confidence:* #{confidence_pct}%"},
          %{
            type: "mrkdwn",
            text:
              "*Risk Level:* #{risk_emoji} #{String.capitalize(recommendation.risk_level || "medium")}"
          },
          %{
            type: "mrkdwn",
            text: "*Est. Recovery:* #{recommendation.estimated_recovery_time || "Unknown"}"
          }
        ]
      },
      %{
        type: "section",
        text: %{
          type: "mrkdwn",
          text: "*Explanation:*\n#{recommendation.explanation || "No explanation provided."}"
        }
      }
    ] ++
      if recommendation.alternative_action do
        [
          %{
            type: "context",
            elements: [
              %{
                type: "mrkdwn",
                text:
                  "💡 *Alternative:* #{format_action(recommendation.alternative_action)} (if primary action fails)"
              }
            ]
          }
        ]
      else
        []
      end ++
      [
        %{type: "divider"},
        %{
          type: "actions",
          elements: [
            %{
              type: "button",
              text: %{type: "plain_text", text: "✅ Confirm & Execute"},
              style: "primary",
              action_id: "confirm_auto_fix",
              value: "confirm:#{incident.id}:#{recommendation.recommended_action}"
            },
            %{
              type: "button",
              text: %{type: "plain_text", text: "❌ Cancel"},
              style: "danger",
              action_id: "cancel_auto_fix",
              value: "cancel:#{incident.id}"
            },
            %{
              type: "button",
              text: %{type: "plain_text", text: "💬 Start Chat"},
              action_id: "start_chat",
              value: "start_chat:#{incident.id}"
            }
          ]
        }
      ]
  end

  defp build_fallback_recommendation_blocks(incident) do
    [
      %{
        type: "header",
        text: %{
          type: "plain_text",
          text: "⚠️ Fallback Recommendation"
        }
      },
      %{
        type: "section",
        text: %{
          type: "mrkdwn",
          text: "*Service:* #{incident.service_name}\n*Incident ID:* `#{incident.id}`"
        }
      },
      %{
        type: "section",
        text: %{
          type: "mrkdwn",
          text:
            "AI analysis was unavailable. Using the default recommended action based on incident analysis."
        }
      },
      %{
        type: "section",
        text: %{
          type: "mrkdwn",
          text:
            "*Recommended Action:* #{format_action(incident.recommended_action || "manual_fix")}"
        }
      },
      %{type: "divider"},
      %{
        type: "actions",
        elements: [
          %{
            type: "button",
            text: %{type: "plain_text", text: "✅ Confirm & Execute"},
            style: "primary",
            action_id: "confirm_auto_fix",
            value: "confirm:#{incident.id}:#{incident.recommended_action || "manual_fix"}"
          },
          %{
            type: "button",
            text: %{type: "plain_text", text: "❌ Cancel"},
            style: "danger",
            action_id: "cancel_auto_fix",
            value: "cancel:#{incident.id}"
          },
          %{
            type: "button",
            text: %{type: "plain_text", text: "💬 Start Chat"},
            action_id: "start_chat",
            value: "start_chat:#{incident.id}"
          }
        ]
      }
    ]
  end

  defp build_ignore_confirmation_blocks(incident) do
    [
      %{
        type: "header",
        text: %{
          type: "plain_text",
          text: "🚫 Incident Ignored"
        }
      },
      %{
        type: "section",
        text: %{
          type: "mrkdwn",
          text: "This incident has been marked as ignored and will not trigger further alerts."
        }
      },
      %{type: "divider"},
      %{
        type: "section",
        fields: [
          %{type: "mrkdwn", text: "*Service:*\n#{incident.service_name}"},
          %{type: "mrkdwn", text: "*Severity:*\n#{incident.severity}"},
          %{type: "mrkdwn", text: "*Detected:*\n#{format_timestamp(incident.detected_at)}"},
          %{type: "mrkdwn", text: "*Status:*\nIgnored"}
        ]
      },
      %{
        type: "section",
        text: %{
          type: "mrkdwn",
          text: "*Root Cause:*\n#{incident.root_cause || "Not determined"}"
        }
      },
      %{
        type: "context",
        elements: [
          %{
            type: "mrkdwn",
            text:
              "ℹ️ This incident remains in the database for audit purposes. You can reopen it from the dashboard if needed."
          }
        ]
      }
    ]
  end
end
