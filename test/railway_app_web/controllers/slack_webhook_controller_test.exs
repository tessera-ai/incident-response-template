defmodule RailwayAppWeb.SlackWebhookControllerTest do
  use RailwayAppWeb.ConnCase, async: false

  setup do
    # Store and restore original configs
    original_slack = Application.get_env(:railway_app, :slack, [])
    original_railway = Application.get_env(:railway_app, :railway, [])
    original_llm = Application.get_env(:railway_app, :llm, [])

    # Set minimal config for testing
    Application.put_env(:railway_app, :slack, signing_secret: "test_secret")

    on_exit(fn ->
      Application.put_env(:railway_app, :slack, original_slack)
      Application.put_env(:railway_app, :railway, original_railway)
      Application.put_env(:railway_app, :llm, original_llm)
    end)

    :ok
  end

  # =============================================================================
  # Interactive Endpoint
  # =============================================================================

  describe "POST /api/slack/interactive" do
    test "returns 400 when payload is missing", %{conn: conn} do
      conn = post(conn, "/api/slack/interactive", %{})
      assert response(conn, 400) =~ "Missing payload"
    end

    test "returns 400 when payload is invalid JSON", %{conn: conn} do
      conn = post(conn, "/api/slack/interactive", %{"payload" => "invalid{json"})
      assert response(conn, 400) =~ "Invalid payload"
    end

    test "returns 200 for valid auto_fix action", %{conn: conn} do
      payload =
        Jason.encode!(%{
          "type" => "block_actions",
          "actions" => [
            %{
              "action_id" => "auto_fix",
              "value" => "auto_fix:incident_123"
            }
          ],
          "channel" => %{"id" => "C123456"},
          "message" => %{"ts" => "1234567890.123456"},
          "user" => %{"id" => "U123456"}
        })

      conn = post(conn, "/api/slack/interactive", %{"payload" => payload})
      assert response(conn, 200) == ""
    end

    test "returns 200 for valid start_chat action", %{conn: conn} do
      payload =
        Jason.encode!(%{
          "type" => "block_actions",
          "actions" => [
            %{
              "action_id" => "start_chat",
              "value" => "start_chat:incident_123"
            }
          ],
          "channel" => %{"id" => "C123456"},
          "message" => %{"ts" => "1234567890.123456"},
          "user" => %{"id" => "U123456"}
        })

      conn = post(conn, "/api/slack/interactive", %{"payload" => payload})
      assert response(conn, 200) == ""
    end

    test "returns 200 for valid ignore action", %{conn: conn} do
      payload =
        Jason.encode!(%{
          "type" => "block_actions",
          "actions" => [
            %{
              "action_id" => "ignore",
              "value" => "ignore:incident_123"
            }
          ],
          "channel" => %{"id" => "C123456"},
          "message" => %{"ts" => "1234567890.123456"},
          "user" => %{"id" => "U123456"}
        })

      conn = post(conn, "/api/slack/interactive", %{"payload" => payload})
      assert response(conn, 200) == ""
    end

    test "returns 200 for valid confirm_auto_fix action", %{conn: conn} do
      payload =
        Jason.encode!(%{
          "type" => "block_actions",
          "actions" => [
            %{
              "action_id" => "confirm_auto_fix",
              "value" => "confirm:incident_123:restart"
            }
          ],
          "channel" => %{"id" => "C123456"},
          "message" => %{"ts" => "1234567890.123456"},
          "user" => %{"id" => "U123456"}
        })

      conn = post(conn, "/api/slack/interactive", %{"payload" => payload})
      assert response(conn, 200) == ""
    end

    test "returns 200 for valid cancel_auto_fix action", %{conn: conn} do
      payload =
        Jason.encode!(%{
          "type" => "block_actions",
          "actions" => [
            %{
              "action_id" => "cancel_auto_fix",
              "value" => "cancel:incident_123"
            }
          ],
          "channel" => %{"id" => "C123456"},
          "message" => %{"ts" => "1234567890.123456"},
          "user" => %{"id" => "U123456"}
        })

      conn = post(conn, "/api/slack/interactive", %{"payload" => payload})
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

      conn = post(conn, "/api/slack/interactive", %{"payload" => payload})
      assert response(conn, 200) == ""
    end

    test "handles unknown interaction type gracefully", %{conn: conn} do
      payload =
        Jason.encode!(%{
          "type" => "unknown_type",
          "actions" => []
        })

      conn = post(conn, "/api/slack/interactive", %{"payload" => payload})
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

      conn = post(conn, "/api/slack/slash", params)
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

      conn = post(conn, "/api/slack/slash", params)
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

      conn = post(conn, "/api/slack/slash", params)
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

      conn = post(conn, "/api/slack/slash", params)
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

      conn = post(conn, "/api/slack/slash", params)
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

      conn = post(conn, "/api/slack/slash", params)
      assert json_response(conn, 200)["text"] == "Processing your request..."
    end
  end

  # =============================================================================
  # Action Value Parsing
  # =============================================================================

  describe "action value parsing" do
    test "parses auto_fix value correctly" do
      value = "auto_fix:incident_123"
      [action, id] = String.split(value, ":")

      assert action == "auto_fix"
      assert id == "incident_123"
    end

    test "parses confirm value correctly" do
      value = "confirm:incident_123:restart"
      [action, incident_id, recommended_action] = String.split(value, ":")

      assert action == "confirm"
      assert incident_id == "incident_123"
      assert recommended_action == "restart"
    end

    test "parses cancel value correctly" do
      value = "cancel:incident_123"
      [action, id] = String.split(value, ":")

      assert action == "cancel"
      assert id == "incident_123"
    end
  end
end
