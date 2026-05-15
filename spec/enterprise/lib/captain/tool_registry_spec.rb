require 'rails_helper'

RSpec.describe Captain::ToolRegistry do
  describe '.tools_for_scope' do
    it 'keeps shared agent tools available in the assistant scope' do
      agent_tool_ids = described_class.tools_for_scope(Captain::ToolAccess::SCOPE_AGENT).pluck(:id)
      assistant_tool_ids = described_class.tools_for_scope(Captain::ToolAccess::SCOPE_ASSISTANT).pluck(:id)

      expect(agent_tool_ids - assistant_tool_ids).to be_empty
      expect(assistant_tool_ids).to include(
        'search_documentation',
        'list_captain_documents',
        'faq_lookup',
        'create_deal',
        'list_deal_pipelines',
        'list_deal_stages',
        'list_deal_custom_fields',
        'list_task_custom_fields',
        'list_appointment_custom_fields',
        'create_appointment',
        'create_touch',
        'cancel_touch',
        'delete_touch',
        'cancel_touches',
        'create_touch_plan',
        'apply_touch_plan',
        'archive_touch_plan',
        'list_channel_templates',
        'list_scheduling_resources',
        'search_scheduling_resources',
        'get_scheduling_resource_schedule',
        'get_scheduling_resource_availability',
        'send_message_to_conversation',
        'cancel_response',
        'send_notification',
        'assign_conversation',
        'search_canned_responses',
        'create_canned_response',
        'create_contact',
        'complete_task',
        'merge_contacts',
        'add_appointment_payment',
        'get_kaspi_pay_integration_status',
        'start_kaspi_pay_connection',
        'send_kaspi_pay_phone',
        'verify_kaspi_pay_otp',
        'disconnect_kaspi_pay',
        'create_kaspi_pay_payment',
        'get_kaspi_pay_payment_status',
        'search_kaspi_pay_payments',
        'get_kaspi_pay_payment',
        'sync_kaspi_pay_payment_status',
        'execute_macro',
        'get_account_health',
        'get_recent_account_errors',
        'get_tool_execution_log',
        'trace_ai_response',
        'trace_message_delivery',
        'get_channel_health',
        'get_whatsapp_web_diagnostics',
        'reconnect_whatsapp_web',
        'retry_failed_message',
        'edit_message',
        'translate_message',
        'create_label',
        'update_label',
        'remove_label_from_conversation',
        'list_campaigns',
        'preview_campaign',
        'get_campaign_analytics',
        'retry_failed_campaign_deliveries',
        'create_webhook',
        'update_webhook'
      )
    end

    it 'opens non-admin business tools to the customer-facing agent scope' do
      agent_tool_ids = described_class.tools_for_scope(Captain::ToolAccess::SCOPE_AGENT).pluck(:id)

      expect(agent_tool_ids).to include(*expected_agent_business_tool_ids)
      expect(agent_tool_ids).not_to include(*assistant_only_admin_tool_ids)
      expect(agent_tool_ids.size).to eq(77)
    end

    it 'keeps explicit admin, finance, automation, and operational tools assistant-only' do
      agent_tool_ids = described_class.tools_for_scope(Captain::ToolAccess::SCOPE_AGENT).pluck(:id)
      assistant_tool_ids = described_class.tools_for_scope(Captain::ToolAccess::SCOPE_ASSISTANT).pluck(:id)

      expect(agent_tool_ids).not_to include(*assistant_only_admin_tool_ids)
      expect(assistant_tool_ids).to include(*assistant_only_admin_tool_ids)
    end

    it 'annotates built-in tools with risk and scope metadata' do
      definition = described_class.tools_for_scope(Captain::ToolAccess::SCOPE_AGENT).find { |tool| tool[:id] == 'create_deal' }

      expect(definition).to include(
        id: 'create_deal',
        risk_level: 'high',
        allowed_scopes: %w[agent assistant],
        required_features: ['crm_deals'],
        required_permissions: ['crm_deal_manage']
      )

      list_pipelines = described_class.tools_for_scope(Captain::ToolAccess::SCOPE_AGENT).find { |tool| tool[:id] == 'list_deal_pipelines' }
      list_stages = described_class.tools_for_scope(Captain::ToolAccess::SCOPE_AGENT).find { |tool| tool[:id] == 'list_deal_stages' }
      list_deal_fields = described_class.tools_for_scope(Captain::ToolAccess::SCOPE_AGENT).find { |tool| tool[:id] == 'list_deal_custom_fields' }

      expect(list_pipelines).to include(
        id: 'list_deal_pipelines',
        risk_level: 'low',
        idempotent: true,
        required_features: ['crm_deals'],
        required_permissions: %w[crm_deal_view crm_deal_manage]
      )
      expect(list_stages).to include(
        id: 'list_deal_stages',
        risk_level: 'low',
        idempotent: true,
        required_features: ['crm_deals'],
        required_permissions: %w[crm_deal_view crm_deal_manage]
      )
      expect(list_deal_fields).to include(
        id: 'list_deal_custom_fields',
        risk_level: 'low',
        idempotent: true,
        required_features: ['crm_deals'],
        required_permissions: %w[crm_deal_view crm_deal_manage]
      )
    end

    it 'marks capability tools that are controlled through assistant settings checkboxes' do
      handoff = described_class.tools_for_scope(Captain::ToolAccess::SCOPE_AGENT).find { |tool| tool[:id] == 'handoff' }
      cancel_response = described_class.tools_for_scope(Captain::ToolAccess::SCOPE_AGENT).find { |tool| tool[:id] == 'cancel_response' }
      send_notification = described_class.tools_for_scope(Captain::ToolAccess::SCOPE_AGENT).find { |tool| tool[:id] == 'send_notification' }
      add_private_note = described_class.tools_for_scope(Captain::ToolAccess::SCOPE_ASSISTANT).find { |tool| tool[:id] == 'add_private_note' }

      expect(handoff).to include(id: 'handoff', capability_tool: true)
      expect(cancel_response).to include(id: 'cancel_response', capability_tool: true, risk_level: 'low', idempotent: true)
      expect(send_notification).to include(id: 'send_notification', capability_tool: true, risk_level: 'medium')
      expect(add_private_note).to include(id: 'add_private_note', capability_tool: true)
    end
  end

  describe '.resolve_agent_tool_class' do
    it 'uses the explicit registry mapping for agent tools' do
      expect(described_class.resolve_agent_tool_class('faq_lookup')).to eq(Captain::Tools::FaqLookupTool)
    end

    it 'returns nil for unknown tool ids' do
      expect(described_class.resolve_agent_tool_class('missing_tool')).to be_nil
    end
  end

  describe '.resolve_assistant_tool_class' do
    it 'uses the explicit registry mapping for assistant tools' do
      expect(described_class.resolve_assistant_tool_class('faq_lookup')).to eq(Captain::Tools::Copilot::FaqLookupService)
    end
  end

  describe 'definition integrity' do
    it 'declares an explicit runtime class for every supported scope' do
      described_class.definitions.each do |definition|
        if definition.supports_scope?(Captain::ToolAccess::SCOPE_AGENT)
          expect(definition.tool_class_for(Captain::ToolAccess::SCOPE_AGENT)).to be_a(Class)
        end

        if definition.supports_scope?(Captain::ToolAccess::SCOPE_ASSISTANT)
          expect(definition.tool_class_for(Captain::ToolAccess::SCOPE_ASSISTANT)).to be_a(Class)
        end
      end
    end
  end

  def expected_agent_business_tool_ids
    all_tool_ids - assistant_only_admin_tool_ids
  end

  def all_tool_ids
    described_class.definitions.map(&:id)
  end

  def assistant_only_admin_tool_ids
    %w[
      add_appointment_payment
      get_kaspi_pay_integration_status
      start_kaspi_pay_connection
      send_kaspi_pay_phone
      verify_kaspi_pay_otp
      disconnect_kaspi_pay
      search_kaspi_pay_payments
      get_kaspi_pay_payment
      sync_kaspi_pay_payment_status
      execute_macro
      create_contact
      complete_task
      list_account_users
      list_teams
      get_account_health
      get_recent_account_errors
      get_tool_execution_log
      trace_ai_response
      trace_message_delivery
      get_channel_health
      get_whatsapp_web_diagnostics
      reconnect_whatsapp_web
      create_label
      update_label
      retry_failed_campaign_deliveries
      create_webhook
      update_webhook
    ]
  end
end
