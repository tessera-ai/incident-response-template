defmodule RailwayAppWeb.SlackWebhookControllerTest do
  use RailwayAppWeb.ConnCase, async: false

  alias RailwayApp.{Incident, Repo}

  @signing_secret "test_secret"

  setup do
    # Store and restore original configs
    original_slack = Application.get_env(:railway_app, :slack, [])
    original_railway = Application.get_env(:railway_app, :railway, [])
    original_llm = Application.get_env(:railway_app, :llm, [])

    # Set minimal config for testing
    Application.put_env(:railway_app, :slack, signing_secret: @signing_secret)

    on_exit(fn ->
      Application.put_env(:railway_app, :slack, original_slack)
      Application.put_env(:railway_app, :railway, original_railway)
      Application.put_env(:railway_app, :llm, original_llm)
    end)

    {:ok, incident: insert_incident()}
  end

  defp insert_incident do
    {:ok, incident} =
      %Incident{}
      |> Incident.changeset(%{
        service_id: "svc_test",
        service_name: "test-service",
        severity: "high",
        status: "detected",
        confidence: 0.85,
        root_cause: "Test incident",
        recommended_action: "restart",
        detected_at: DateTime.utc_now()
      })
      |> Repo.insert()

    incident
  end

  # Signs a request body using Slack's HMAC-SHA256 scheme.
  defp sign_slack_request(conn, body) do
    timestamp = System.system_time(:second) |> Integer.to_string()
    basestring = "v0:#{timestamp}:#{body}"
    hash = :crypto.mac(:hmac, :sha256, @signing_secret, basestring)
    signature = "v0=" <> Base.encode16(hash, case: :lower)

    conn
    |> Plug.Conn.put_req_header("x-slack-request-timestamp", timestamp)
    |> Plug.Conn.put_req_header("x-slack-signature", signature)
  end

  # Posts URL-encoded body with valid Slack signature.
  defp signed_post(conn, path, params) when is_map(params) do
    body = URI.encode_query(params)

    conn
    |> Plug.Conn.put_req_header("content-type", "application/x-www-form-urlencoded")
    |> sign_slack_request(body)
    |> post(path, body)
  end

  # Posts raw body string with valid Slack signature and given content-type.
  defp signed_post(conn, path, body, content_type) when is_binary(body) do
    conn
    |> Plug.Conn.put_req_header("content-type", content_type)
    |> sign_slack_request(body)
    |> post(path, body)
  end

  # =============================================================================
  # Signature Verification
  # =============================================================================

  describe "Slack signature verification" do
    test "rejects request with no signature headers", %{conn: conn} do
      params = %{"command" => "/tessera", "text" => "help"}
      body = URI.encode_query(params)

      conn =
        conn
        |> Plug.Conn.put_req_header("content-type", "application/x-www-form-urlencoded")
        |> post("/api/slack/slash", body)

      assert response(conn, 401) =~ "Unauthorized"
    end

    test "rejects request with wrong signing secret", %{conn: conn} do
      params = %{"command" => "/tessera", "text" => "help"}
      body = URI.encode_query(params)

      # Sign with wrong secret
      timestamp = System.system_time(:second) |> Integer.to_string()
      hash = :crypto.mac(:hmac, :sha256, "wrong_secret", "v0:#{timestamp}:#{body}")
      signature = "v0=" <> Base.encode16(hash, case: :lower)

      conn =
        conn
        |> Plug.Conn.put_req_header("content-type", "application/x-www-form-urlencoded")
        |> Plug.Conn.put_req_header("x-slack-request-timestamp", timestamp)
        |> Plug.Conn.put_req_header("x-slack-signature", signature)
        |> post("/api/slack/slash", body)

      assert response(conn, 401) =~ "Unauthorized"
    end

    test "rejects request with stale timestamp", %{conn: conn} do
      params = %{"command" => "/tessera", "text" => "help"}
      body = URI.encode_query(params)

      # Use a timestamp 10 minutes old
      stale_timestamp = (System.system_time(:second) - 600) |> Integer.to_string()
      hash = :crypto.mac(:hmac, :sha256, @signing_secret, "v0:#{stale_timestamp}:#{body}")
      signature = "v0=" <> Base.encode16(hash, case: :lower)

      conn =
        conn
        |> Plug.Conn.put_req_header("content-type", "application/x-www-form-urlencoded")
        |> Plug.Conn.put_req_header("x-slack-request-timestamp", stale_timestamp)
        |> Plug.Conn.put_req_header("x-slack-signature", signature)
        |> post("/api/slack/slash", body)

      assert response(conn, 401) =~ "Unauthorized"
    end
  end

  # =============================================================================
  # Interactive Endpoint
  # =============================================================================

  describe "POST /api/slack/interactive" do
    test "returns 400 when payload is missing", %{conn: conn} do
      body = URI.encode_query(%{})

      conn =
        signed_post(conn, "/api/slack/interactive", body, "application/x-www-form-urlencoded")

      assert response(conn, 400) =~ "Missing payload"
    end

    test "returns 400 when payload is invalid JSON", %{conn: conn} do
      body = URI.encode_query(%{"payload" => "invalid{json"})

      conn =
        signed_post(conn, "/api/slack/interactive", body, "application/x-www-form-urlencoded")

      assert response(conn, 400) =~ "Invalid payload"
    end

    test "returns 200 for valid auto_fix action", %{conn: conn, incident: incident} do
      payload =
        Jason.encode!(%{
          "type" => "block_actions",
          "actions" => [
            %{
              "action_id" => "auto_fix",
              "value" => "auto_fix:#{incident.id}"
            }
          ],
          "channel" => %{"id" => "C123456"},
          "message" => %{"ts" => "1234567890.123456"},
          "user" => %{"id" => "U123456"}
        })

      conn = signed_post(conn, "/api/slack/interactive", %{"payload" => payload})
      assert response(conn, 200) == ""
    end

    test "returns 200 for valid start_chat action", %{conn: conn, incident: incident} do
      payload =
        Jason.encode!(%{
          "type" => "block_actions",
          "actions" => [
            %{
              "action_id" => "start_chat",
              "value" => "start_chat:#{incident.id}"
            }
          ],
          "channel" => %{"id" => "C123456"},
          "message" => %{"ts" => "1234567890.123456"},
          "user" => %{"id" => "U123456"}
        })

      conn = signed_post(conn, "/api/slack/interactive", %{"payload" => payload})
      assert response(conn, 200) == ""
    end

    test "returns 200 for valid ignore action", %{conn: conn, incident: incident} do
      payload =
        Jason.encode!(%{
          "type" => "block_actions",
          "actions" => [
            %{
              "action_id" => "ignore",
              "value" => "ignore:#{incident.id}"
            }
          ],
          "channel" => %{"id" => "C123456"},
          "message" => %{"ts" => "1234567890.123456"},
          "user" => %{"id" => "U123456"}
        })

      conn = signed_post(conn, "/api/slack/interactive", %{"payload" => payload})
      assert response(conn, 200) == ""
    end

    test "returns 200 for valid confirm_auto_fix action", %{conn: conn, incident: incident} do
      payload =
        Jason.encode!(%{
          "type" => "block_actions",
          "actions" => [
            %{
              "action_id" => "confirm_auto_fix",
              "value" => "confirm:#{incident.id}:restart"
            }
          ],
          "channel" => %{"id" => "C123456"},
          "message" => %{"ts" => "1234567890.123456"},
          "user" => %{"id" => "U123456"}
        })

      conn = signed_post(conn, "/api/slack/interactive", %{"payload" => payload})
      assert response(conn, 200) == ""
    end

    test "returns 200 for valid cancel_auto_fix action", %{conn: conn, incident: incident} do
      payload =
        Jason.encode!(%{
          "type" => "block_actions",
          "actions" => [
            %{
              "action_id" => "cancel_auto_fix",
              "value" => "cancel:#{incident.id}"
            }
          ],
          "channel" => %{"id" => "C123456"},
          "message" => %{"ts" => "1234567890.123456"},
          "user" => %{"id" => "U123456"}
        })

      conn = signed_post(conn, "/api/slack/interactive", %{"payload" => payload})
      assert response(conn, 200) == ""
    end

    test "handles unknown action gracefully", %{conn: conn} do
      payload =
        Jason.encode!(%{
          "type" => "block_actions",
          "actions" => [
            %{
              "action_id" => "unknown_action",
              "value" => "unknown:123"
            }
          ],
          "channel" => %{"id" => "C123456"},
          "message" => %{"ts" => "1234567890.123456"}
        })

      conn = signed_post(conn, "/api/slack/interactive", %{"payload" => payload})
      assert response(conn, 200) == ""
    end

    test "handles unknown interaction type gracefully", %{conn: conn} do
      payload =
        Jason.encode!(%{
          "type" => "unknown_type",
          "actions" => []
        })

      conn = signed_post(conn, "/api/slack/interactive", %{"payload" => payload})
      assert response(conn, 200) == ""
    end
  end

  # =============================================================================
  # Slash Command Endpoint
  # =============================================================================

  describe "POST /api/slack/slash" do
    test "returns 200 with processing message", %{conn: conn} do
      params = %{
        "command" => "/tessera",
        "text" => "status api-service",
        "user_id" => "U123456",
        "channel_id" => "C123456",
        "response_url" => "https://hooks.slack.com/commands/test"
      }

      conn = signed_post(conn, "/api/slack/slash", params)
      assert json_response(conn, 200)["text"] == "Processing your request..."
    end

    test "handles empty text", %{conn: conn} do
      params = %{
        "command" => "/tessera",
        "text" => "",
        "user_id" => "U123456",
        "channel_id" => "C123456",
        "response_url" => "https://hooks.slack.com/commands/test"
      }

      conn = signed_post(conn, "/api/slack/slash", params)
      assert json_response(conn, 200)["response_type"] == "ephemeral"
    end

    test "handles restart command", %{conn: conn} do
      params = %{
        "command" => "/tessera",
        "text" => "restart svc_123",
        "user_id" => "U123456",
        "channel_id" => "C123456",
        "response_url" => "https://hooks.slack.com/commands/test"
      }

      conn = signed_post(conn, "/api/slack/slash", params)
      assert json_response(conn, 200)["text"] == "Processing your request..."
    end

    test "handles scale command", %{conn: conn} do
      params = %{
        "command" => "/tessera",
        "text" => "scale memory 2048",
        "user_id" => "U123456",
        "channel_id" => "C123456",
        "response_url" => "https://hooks.slack.com/commands/test"
      }

      conn = signed_post(conn, "/api/slack/slash", params)
      assert json_response(conn, 200)["text"] == "Processing your request..."
    end

    test "handles status command", %{conn: conn} do
      params = %{
        "command" => "/tessera",
        "text" => "status",
        "user_id" => "U123456",
        "channel_id" => "C123456",
        "response_url" => "https://hooks.slack.com/commands/test"
      }

      conn = signed_post(conn, "/api/slack/slash", params)
      assert json_response(conn, 200)["text"] == "Processing your request..."
    end

    test "handles help command", %{conn: conn} do
      params = %{
        "command" => "/tessera",
        "text" => "help",
        "user_id" => "U123456",
        "channel_id" => "C123456",
        "response_url" => "https://hooks.slack.com/commands/test"
      }

      conn = signed_post(conn, "/api/slack/slash", params)
      assert json_response(conn, 200)["text"] == "Processing your request..."
    end
  end

  # =============================================================================
  # Action Value Parsing
  # =============================================================================

  describe "action value parsing" do
    test "parses auto_fix value correctly" do
      incident_id = Ecto.UUID.generate()
      value = "auto_fix:#{incident_id}"
      [action, parsed_id] = String.split(value, ":")

      assert action == "auto_fix"
      assert parsed_id == incident_id
    end

    test "parses confirm value correctly" do
      incident_id = Ecto.UUID.generate()
      value = "confirm:#{incident_id}:restart"
      [action, parsed_id, recommended_action] = String.split(value, ":")

      assert action == "confirm"
      assert parsed_id == incident_id
      assert recommended_action == "restart"
    end

    test "parses cancel value correctly" do
      incident_id = Ecto.UUID.generate()
      value = "cancel:#{incident_id}"
      [action, parsed_id] = String.split(value, ":")

      assert action == "cancel"
      assert parsed_id == incident_id
    end
  end
end
