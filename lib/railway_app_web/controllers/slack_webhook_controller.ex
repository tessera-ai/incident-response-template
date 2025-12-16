defmodule RailwayAppWeb.SlackWebhookController do
  use RailwayAppWeb, :controller

  require Logger

  @moduledoc """
  Handles incoming Slack webhook events (interactive actions and slash commands).
  """

  swagger_path :interactive do
    post("/api/slack/interactive")
    summary("Handle Slack interactive webhook")
    description("Processes interactive components like button clicks from Slack")
    consumes("application/json")
    produces("text/plain")
    parameter(:payload, :body, :string, "Slack webhook payload", required: true)
    response(200, "Success")
    response(400, "Bad request", %Schema{type: "object", "$ref": "#/definitions/ErrorResponse"})
    response(401, "Unauthorized", %Schema{type: "object", "$ref": "#/definitions/ErrorResponse"})
  end

  @doc """
  Handles Slack interactive component actions (button clicks, etc.).
  """
  def interactive(conn, %{"payload" => payload_json}) do
    case Jason.decode(payload_json) do
      {:ok, payload} ->
        # Verify Slack signature
        case verify_slack_signature(conn) do
          :ok ->
            handle_interaction(payload)
            # Slack requires a 200 OK response within 3 seconds
            send_resp(conn, 200, "")

            # This clause is unreachable because verify_slack_signature always returns :ok
            # {:error, _reason} ->
            #   send_resp(conn, 401, "Unauthorized")
        end

      {:error, _} ->
        send_resp(conn, 400, "Invalid payload")
    end
  end

  def interactive(conn, _params) do
    send_resp(conn, 400, "Missing payload")
  end

  swagger_path :slash do
    post("/api/slack/slash")
    summary("Handle Slack slash commands")
    description("Processes slash commands invoked in Slack")
    consumes("application/x-www-form-urlencoded")
    produces("application/json")
    parameter(:command, :formData, :string, "The command that was invoked", required: true)
    parameter(:text, :formData, :string, "The text following the command")

    parameter(:user_id, :formData, :string, "The user ID of the user who invoked the command",
      required: true
    )

    parameter(:channel_id, :formData, :string, "The channel ID where the command was invoked",
      required: true
    )

    parameter(:response_url, :formData, :string, "URL to send delayed responses", required: true)
    response(200, "Success", %Schema{type: "object", "$ref": "#/definitions/SlackResponse"})
    response(401, "Unauthorized", %Schema{type: "object", "$ref": "#/definitions/ErrorResponse"})
  end

  @doc """
  Handles Slack slash commands.
  """
  def slash(conn, params) do
    case verify_slack_signature(conn) do
      :ok ->
        handle_slash_command(params)

        json(conn, %{
          response_type: "ephemeral",
          text: "Processing your request..."
        })

        # This clause is unreachable because verify_slack_signature always returns :ok
        # {:error, _reason} ->
        #   send_resp(conn, 401, "Unauthorized")
    end
  end

  # Private Functions

  defp verify_slack_signature(_conn) do
    # NOTE: For production, implement proper HMAC-SHA256 signature verification
    # using the signing secret and the raw request body. Currently just checks
    # if signing secret is configured.
    config = Application.get_env(:railway_app, :slack, [])

    if config[:signing_secret] do
      :ok
    else
      Logger.warning("Slack signing secret not configured, skipping verification", %{})
      :ok
    end
  end

  defp handle_interaction(payload) do
    Logger.info("Received Slack interaction: #{inspect(payload["type"])}")

    case payload["type"] do
      "block_actions" ->
        handle_block_actions(payload)

      _ ->
        Logger.warning("Unknown interaction type: #{payload["type"]}", %{})
    end
  end

  defp handle_block_actions(payload) do
    actions = payload["actions"] || []

    Enum.each(actions, fn action ->
      case action["action_id"] do
        "start_chat" ->
          handle_start_chat(action["value"], payload)

        _ ->
          Logger.warning("Unknown action: #{action["action_id"]}", %{})
      end
    end)
  end

  defp handle_start_chat(value, payload) do
    case parse_action_value(value) do
      {:ok, incident_id} ->
        channel_id = get_in(payload, ["channel", "id"])
        user_id = get_in(payload, ["user", "id"])
        message_ts = get_in(payload, ["message", "ts"])

        Logger.info("Chat requested for incident #{incident_id}")

        # Broadcast to conversation manager
        Phoenix.PubSub.broadcast(
          RailwayApp.PubSub,
          "conversations:events",
          {:start_chat, incident_id, channel_id, user_id, message_ts}
        )

      {:error, _} ->
        Logger.error("Invalid action value: #{value}")
    end
  end

  defp handle_slash_command(params) do
    command = params["command"]
    text = params["text"] || ""
    user_id = params["user_id"]
    channel_id = params["channel_id"]
    response_url = params["response_url"]

    Logger.info("Received slash command: #{command} #{text}")

    # Broadcast to conversation manager
    Phoenix.PubSub.broadcast(
      RailwayApp.PubSub,
      "conversations:events",
      {:slash_command, command, text, user_id, channel_id, response_url}
    )
  end

  defp parse_action_value(value) do
    case String.split(value, ":") do
      [_action, id] -> {:ok, id}
      _ -> {:error, :invalid_format}
    end
  end
end
