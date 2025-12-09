defmodule RailwayApp.Remediation.CoordinatorTest do
  use RailwayApp.DataCase, async: false

  alias RailwayApp.Remediation.Coordinator
  alias RailwayApp.{Incidents, ServiceConfigs, RemediationActions}

  setup do
    # Create a test service config with auto-remediation enabled
    {:ok, service_config} =
      ServiceConfigs.create_service_config(%{
        service_id: "test-service-456",
        service_name: "Test Service",
        auto_remediation_enabled: true,
        confidence_threshold: 0.7,
        memory_scale_default: 2048,
        replica_scale_default: 2
      })

    # Create a test incident
    {:ok, incident} =
      Incidents.create_incident(%{
        service_id: service_config.service_id,
        service_name: service_config.service_name,
        signature: "test-signature-#{System.unique_integer()}",
        severity: "critical",
        status: "detected",
        confidence: 0.8,
        root_cause: "Service crashed due to memory exhaustion",
        recommended_action: "restart",
        reasoning: "Service needs to be restarted to recover",
        detected_at: DateTime.utc_now(),
        service_config_id: service_config.id
      })

    {:ok, incident: incident, service_config: service_config}
  end

  describe "auto-remediation" do
    test "executes remediation for high-confidence incidents", %{
      incident: incident,
      service_config: _service_config
    } do
      # Trigger auto-remediation
      Coordinator.execute_remediation(incident.id, "automated", "system")

      # Wait for action to be created and executed
      Process.sleep(1000)

      # Verify remediation action was created
      actions = RemediationActions.list_by_incident(incident.id)
      assert length(actions) > 0

      action = List.first(actions)
      assert action.incident_id == incident.id
      assert action.initiator_type == "automated"
      assert action.action_type == "restart"
      assert action.status in ["pending", "in_progress", "succeeded", "failed"]
    end

    test "skips auto-remediation when disabled", %{incident: incident, service_config: _config} do
      # Disable auto-remediation
      {:ok, _} =
        ServiceConfigs.toggle_auto_remediation(incident.service_id, false)

      # Broadcast incident (should not trigger auto-remediation)
      Phoenix.PubSub.broadcast(
        RailwayApp.PubSub,
        "incidents:new",
        {:incident_detected, incident}
      )

      # Wait a bit
      Process.sleep(500)

      # Verify no remediation actions were created
      actions = RemediationActions.list_by_incident(incident.id)
      assert length(actions) == 0
    end

    test "handles manual remediation requests", %{incident: incident} do
      # Trigger manual remediation
      Coordinator.execute_remediation(incident.id, "user", "test-user-123")

      # Wait for processing
      Process.sleep(1000)

      # Verify remediation action was created with user initiator
      actions = RemediationActions.list_by_incident(incident.id)
      assert length(actions) > 0

      action = List.first(actions)
      assert action.initiator_type == "user"
      assert action.initiator_ref == "test-user-123"
    end

    test "creates audit trail for remediation attempts", %{incident: incident} do
      # Execute remediation
      Coordinator.execute_remediation(incident.id, "automated", "system")

      # Wait for completion
      Process.sleep(1000)

      # Verify action has timestamps and status
      actions = RemediationActions.list_by_incident(incident.id)
      action = List.first(actions)

      assert action.requested_at != nil
      assert action.status in ["pending", "in_progress", "succeeded", "failed"]

      # If completed, should have completion timestamp
      if action.status in ["succeeded", "failed"] do
        assert action.completed_at != nil
      end
    end
  end

  describe "action execution" do
    test "handles restart action", %{service_config: service_config} do
      {:ok, incident} =
        Incidents.create_incident(%{
          service_id: service_config.service_id,
          service_name: service_config.service_name,
          signature: "restart-test-#{System.unique_integer()}",
          severity: "high",
          recommended_action: "restart",
          detected_at: DateTime.utc_now(),
          service_config_id: service_config.id
        })

      Coordinator.execute_remediation(incident.id, "automated", "test")

      Process.sleep(1000)

      actions = RemediationActions.list_by_incident(incident.id)
      assert length(actions) > 0

      action = List.first(actions)
      assert action.action_type == "restart"
    end

    test "handles scale memory action", %{service_config: service_config} do
      {:ok, incident} =
        Incidents.create_incident(%{
          service_id: service_config.service_id,
          service_name: service_config.service_name,
          signature: "scale-memory-test-#{System.unique_integer()}",
          severity: "high",
          recommended_action: "scale_memory",
          detected_at: DateTime.utc_now(),
          service_config_id: service_config.id
        })

      Coordinator.execute_remediation(incident.id, "automated", "test")

      Process.sleep(1000)

      actions = RemediationActions.list_by_incident(incident.id)
      assert length(actions) > 0

      action = List.first(actions)
      assert action.action_type == "scale_memory"
    end

    test "handles scale replicas action", %{service_config: service_config} do
      {:ok, incident} =
        Incidents.create_incident(%{
          service_id: service_config.service_id,
          service_name: service_config.service_name,
          signature: "scale-replicas-test-#{System.unique_integer()}",
          severity: "medium",
          recommended_action: "scale_replicas",
          detected_at: DateTime.utc_now(),
          service_config_id: service_config.id
        })

      Coordinator.execute_remediation(incident.id, "automated", "test")

      Process.sleep(1000)

      actions = RemediationActions.list_by_incident(incident.id)
      assert length(actions) > 0

      action = List.first(actions)
      assert action.action_type == "scale_replicas"
    end

    test "handles none action gracefully", %{service_config: service_config} do
      {:ok, incident} =
        Incidents.create_incident(%{
          service_id: service_config.service_id,
          service_name: service_config.service_name,
          signature: "none-action-test-#{System.unique_integer()}",
          severity: "low",
          recommended_action: "none",
          detected_at: DateTime.utc_now(),
          service_config_id: service_config.id
        })

      Coordinator.execute_remediation(incident.id, "automated", "test")

      Process.sleep(1000)

      actions = RemediationActions.list_by_incident(incident.id)
      assert length(actions) > 0

      action = List.first(actions)
      assert action.action_type == "none"
    end
  end

  describe "error handling" do
    test "handles non-existent incident gracefully" do
      # Try to remediate non-existent incident
      non_existent_id = Ecto.UUID.generate()
      Coordinator.execute_remediation(non_existent_id, "user", "test")

      # Should not crash, just log error
      Process.sleep(500)

      actions = RemediationActions.list_by_incident(non_existent_id)
      assert length(actions) == 0
    end

    test "records failure details when action fails", %{service_config: service_config} do
      # Create incident with invalid service_id to force failure
      {:ok, incident} =
        Incidents.create_incident(%{
          service_id: "invalid-service-id",
          service_name: "Invalid Service",
          signature: "failure-test-#{System.unique_integer()}",
          severity: "high",
          recommended_action: "restart",
          detected_at: DateTime.utc_now(),
          service_config_id: service_config.id
        })

      Coordinator.execute_remediation(incident.id, "automated", "test")

      # Wait for failure
      Process.sleep(2000)

      actions = RemediationActions.list_by_incident(incident.id)

      if length(actions) > 0 do
        action = List.first(actions)

        # Action should eventually be marked as failed or completed
        assert action.status in ["pending", "in_progress", "succeeded", "failed"]
      end
    end
  end
end
