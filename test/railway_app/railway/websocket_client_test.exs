defmodule RailwayApp.Railway.WebSocketClientTest do
  use ExUnit.Case, async: true
  alias RailwayApp.Railway.WebSocketClient

  describe "handle_log_data/2" do
    test "parses environmentLogs correctly and broadcasts" do
      payload = %{
        "data" => %{
          "environmentLogs" => [
            %{
              "message" => "Env log message",
              "timestamp" => "2023-10-27T10:00:00Z",
              "severity" => "warning"
            }
          ]
        }
      }

      state = %WebSocketClient.State{
        service_id: "test-service-id",
        environment_id: "env-123"
      }

      Phoenix.PubSub.subscribe(RailwayApp.PubSub, "railway:logs:test-service-id")

      {:ok, _state} = WebSocketClient.handle_log_data(payload, state)

      assert_receive {:log_event, log}, 100
      assert log.message == "Env log message"
      assert log.level == "warning"
      assert log.environment_id == "env-123"
      assert log.service_id == "test-service-id"
    end
  end

  describe "subscribe_to_logs/2 (environment logs)" do
    test "builds environmentLogs subscription payload" do
      state = %WebSocketClient.State{
        connection_acknowledged: true,
        subscription_counter: 1,
        subscriptions: %{},
        service_id: "svc",
        environment_id: "env-123",
        project_id: "proj-123",
        token: "tkn"
      }

      {:reply, {:text, frame}, new_state} =
        WebSocketClient.handle_cast({:subscribe, "env-123", %{}}, state)

      decoded = Jason.decode!(frame)
      assert decoded["type"] == "subscribe"
      assert decoded["payload"]["query"] =~ "environmentLogs"
      assert decoded["payload"]["variables"]["environmentId"] == "env-123"
      assert decoded["payload"]["variables"]["filter"] == "severity:error"
      refute String.contains?(decoded["payload"]["query"], "limit:")
      assert new_state.subscription_counter == 2
      assert Map.has_key?(new_state.subscriptions, decoded["id"])
    end
  end
end
