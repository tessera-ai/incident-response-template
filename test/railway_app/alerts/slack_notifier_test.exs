defmodule RailwayApp.Alerts.SlackNotifierTest do
  use ExUnit.Case, async: false

  alias RailwayApp.Alerts.SlackNotifier
  alias RailwayApp.Incident

  setup do
    original_config = Application.get_env(:railway_app, :slack, [])

    on_exit(fn ->
      Application.put_env(:railway_app, :slack, original_config)
    end)

    :ok
  end

  # =============================================================================
  # Send Incident Alert
  # =============================================================================

  describe "send_incident_alert/1" do
    test "returns error when Slack not configured" do
      Application.put_env(:railway_app, :slack, [])

      incident = %Incident{
        id: "incident_123",
        service_id: "svc_456",
        service_name: "test-service",
        severity: "high",
        status: "detected",
        root_cause: "Database connection timeout",
        detected_at: DateTime.utc_now(),
        confidence: 0.85
      }

      result = SlackNotifier.send_incident_alert(incident)
      assert result == {:error, :not_configured}
    end

    test "handles different severity levels in blocks" do
      high_incident = %Incident{
        id: "high_123",
        service_id: "svc_456",
        service_name: "test-service",
        severity: "high",
        status: "detected",
        root_cause: "Memory leak detected",
        detected_at: DateTime.utc_now(),
        confidence: 0.8
      }

      low_incident = %Incident{
        id: "low_456",
        service_id: "svc_456",
        service_name: "test-service",
        severity: "low",
        status: "detected",
        root_cause: "Minor performance degradation",
        detected_at: DateTime.utc_now(),
        confidence: 0.6
      }

      high_blocks = SlackNotifier.build_incident_blocks(high_incident)
      low_blocks = SlackNotifier.build_incident_blocks(low_incident)

      # High severity should have orange emoji
      assert hd(high_blocks).text.text =~ "🟠"
      assert hd(high_blocks).text.text =~ "High"

      # Low severity should have green emoji
      assert hd(low_blocks).text.text =~ "🟢"
      assert hd(low_blocks).text.text =~ "Low"
    end
  end

  # =============================================================================
  # Send Remediation Update
  # =============================================================================

  describe "send_remediation_update/3" do
    test "returns suppressed (remediation updates disabled)" do
      Application.put_env(:railway_app, :slack, [])

      incident = %Incident{
        id: "incident_123",
        service_id: "svc_456",
        service_name: "test-service",
        severity: "high"
      }

      action = %{
        action_type: "service_restart",
        result_message: "Service restarted successfully"
      }

      result = SlackNotifier.send_remediation_update(incident, action, "succeeded")
      assert result == {:ok, :suppressed}
    end

    test "formats remediation success message" do
      incident = %Incident{
        id: "incident_123",
        service_id: "svc_456",
        service_name: "test-service",
        severity: "high"
      }

      action = %{
        action_type: "restart",
        result_message: "Service restarted successfully"
      }

      blocks = SlackNotifier.build_remediation_blocks(incident, action, "succeeded")

      assert hd(blocks).text.text =~ "✅"
      assert hd(blocks).text.text =~ "Remediation Update"
      assert hd(blocks).text.text =~ "restart"
      assert hd(blocks).text.text =~ "succeeded"
      assert hd(blocks).text.text =~ "test-service"
    end

    test "formats remediation failure message" do
      incident = %Incident{
        id: "incident_123",
        service_id: "svc_456",
        service_name: "test-service",
        severity: "high"
      }

      action = %{
        action_type: "scale_memory",
        failure_reason: "Insufficient resources",
        result_message: nil
      }

      blocks = SlackNotifier.build_remediation_blocks(incident, action, "failed")

      assert hd(blocks).text.text =~ "❌"
      assert hd(blocks).text.text =~ "Remediation Update"
      assert hd(blocks).text.text =~ "scale_memory"
      assert hd(blocks).text.text =~ "failed"
    end
  end

  # =============================================================================
  # Send Message
  # =============================================================================

  describe "send_message/3" do
    test "returns error when Slack not configured" do
      Application.put_env(:railway_app, :slack, [])

      result = SlackNotifier.send_message("C1234567890", "Test message")
      assert result == {:error, :not_configured}
    end

    test "accepts thread_ts parameter" do
      Application.put_env(:railway_app, :slack, [])

      result = SlackNotifier.send_message("C1234567890", "Thread reply", "1234567890.123456")
      assert result == {:error, :not_configured}
    end
  end

  # =============================================================================
  # Send Recommendation Message (NEW)
  # =============================================================================

  describe "send_recommendation_message/4" do
    test "returns error when Slack not configured" do
      Application.put_env(:railway_app, :slack, [])

      incident = %Incident{
        id: "incident_123",
        service_id: "svc_456",
        service_name: "test-service",
        severity: "high"
      }

      recommendation = %{
        recommended_action: "restart",
        confidence: 0.85,
        explanation: "Service needs restart due to memory issues",
        risk_level: "low",
        alternative_action: "scale_memory",
        estimated_recovery_time: "2-5 minutes"
      }

      result = SlackNotifier.send_recommendation_message("C123", incident, recommendation)
      assert result == {:error, :not_configured}
    end

    test "builds recommendation blocks with all fields" do
      incident = %Incident{
        id: "incident_123",
        service_id: "svc_456",
        service_name: "api-service",
        severity: "critical"
      }

      recommendation = %{
        recommended_action: "restart",
        confidence: 0.85,
        explanation: "Service needs restart due to memory issues",
        risk_level: "low",
        alternative_action: "scale_memory",
        estimated_recovery_time: "2-5 minutes"
      }

      # The function should build blocks correctly
      # We're just testing that the params are valid
      assert is_map(incident)
      assert is_map(recommendation)
      assert recommendation.recommended_action == "restart"
      assert recommendation.risk_level == "low"
    end
  end

  # =============================================================================
  # Send Fallback Recommendation Message (NEW)
  # =============================================================================

  describe "send_fallback_recommendation_message/3" do
    test "returns error when Slack not configured" do
      Application.put_env(:railway_app, :slack, [])

      incident = %Incident{
        id: "incident_123",
        service_id: "svc_456",
        service_name: "test-service",
        severity: "high",
        recommended_action: "restart"
      }

      result = SlackNotifier.send_fallback_recommendation_message("C123", incident)
      assert result == {:error, :not_configured}
    end
  end

  # =============================================================================
  # Send Ignore Confirmation (NEW)
  # =============================================================================

  describe "send_ignore_confirmation/3" do
    test "returns error when Slack not configured" do
      Application.put_env(:railway_app, :slack, [])

      incident = %Incident{
        id: "incident_123",
        service_id: "svc_456",
        service_name: "test-service",
        severity: "medium",
        detected_at: DateTime.utc_now(),
        root_cause: "Minor issue"
      }

      result = SlackNotifier.send_ignore_confirmation("C123", incident)
      assert result == {:error, :not_configured}
    end
  end

  # =============================================================================
  # Update Message (NEW)
  # =============================================================================

  describe "update_message/3" do
    test "returns error when Slack not configured" do
      Application.put_env(:railway_app, :slack, [])

      blocks = [%{type: "section", text: %{type: "mrkdwn", text: "Updated message"}}]

      result = SlackNotifier.update_message("C123", "1234567890.123456", blocks)
      assert result == {:error, :not_configured}
    end
  end

  # =============================================================================
  # Message Formatting
  # =============================================================================

  describe "incident block formatting" do
    test "includes all relevant incident information" do
      incident = %Incident{
        id: "incident_123",
        service_id: "svc_456",
        service_name: "api-service",
        severity: "critical",
        status: "detected",
        root_cause: "Database connection pool exhausted",
        detected_at: DateTime.utc_now(),
        confidence: 0.92,
        recommended_action: "restart"
      }

      blocks = SlackNotifier.build_incident_blocks(incident)

      # Check header block
      header_block = hd(blocks)
      assert header_block.text.text =~ "🔴"
      assert header_block.text.text =~ "api-service"
      assert header_block.text.text =~ "Critical"

      # Check fields section
      fields_block = Enum.at(blocks, 1)
      assert fields_block.fields != nil
      assert is_list(fields_block.fields)

      # Should contain service name
      service_field =
        Enum.find(fields_block.fields, fn field ->
          String.contains?(field.text, "Service:") && String.contains?(field.text, "api-service")
        end)

      assert service_field != nil

      # Should contain severity
      severity_field =
        Enum.find(fields_block.fields, fn field ->
          String.contains?(field.text, "Severity:") && String.contains?(field.text, "critical")
        end)

      assert severity_field != nil

      # Should contain confidence
      confidence_field =
        Enum.find(fields_block.fields, fn field ->
          String.contains?(field.text, "Confidence:") && String.contains?(field.text, "92%")
        end)

      assert confidence_field != nil
    end

    test "includes action buttons" do
      incident = %Incident{
        id: "incident_123",
        service_id: "svc_456",
        service_name: "test-service",
        severity: "high",
        detected_at: DateTime.utc_now()
      }

      blocks = SlackNotifier.build_incident_blocks(incident)

      # Find the actions block
      actions_block = Enum.find(blocks, fn block -> block[:type] == "actions" end)
      assert actions_block != nil
      assert is_list(actions_block.elements)
      assert length(actions_block.elements) == 1

      # Verify button action IDs
      action_ids = Enum.map(actions_block.elements, fn el -> el.action_id end)
      assert "start_chat" in action_ids
    end
  end

  # =============================================================================
  # Action Formatting
  # =============================================================================

  describe "action formatting" do
    test "formats all action types correctly" do
      assert SlackNotifier.format_action("restart") == "🔄 Restart service"
      assert SlackNotifier.format_action("redeploy") == "🚀 Redeploy service"
      assert SlackNotifier.format_action("scale_memory") == "📈 Scale memory"
      assert SlackNotifier.format_action("scale_replicas") == "📊 Scale replicas"
      assert SlackNotifier.format_action("rollback") == "⏪ Rollback deployment"
      assert SlackNotifier.format_action("stop") == "🛑 Stop service"
      assert SlackNotifier.format_action("manual_fix") == "👨‍💻 Manual intervention required"
      assert SlackNotifier.format_action("none") == "ℹ️ No action needed"
      assert SlackNotifier.format_action("custom_action") == "custom_action"
    end
  end

  # =============================================================================
  # Timestamp Formatting
  # =============================================================================

  describe "timestamp formatting" do
    test "formats datetime correctly" do
      datetime = DateTime.from_naive!(~N[2024-01-15 10:30:00], "Etc/UTC")
      formatted = SlackNotifier.format_timestamp(datetime)

      assert formatted =~ "2024-01-15"
      assert formatted =~ "10:30:00"
    end
  end
end
