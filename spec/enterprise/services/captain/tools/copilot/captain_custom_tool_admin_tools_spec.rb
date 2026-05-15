# frozen_string_literal: true

# rubocop:disable RSpec/DescribeClass
require 'rails_helper'

RSpec.describe 'Captain custom tool admin copilot tools' do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account, name: 'Main Bot') }
  let(:admin) { create(:user, :administrator, account: account) }
  let(:custom_tool) do
    create(
      :captain_custom_tool,
      :with_bearer_auth,
      :with_templates,
      account: account,
      title: 'Fetch Order',
      group_name: 'Orders',
      endpoint_url: 'https://api.example.test/orders/{{ order_id }}?token=secret-token',
      param_schema: [
        { 'name' => 'order_id', 'type' => 'string', 'description' => 'Order ID', 'required' => true },
        { 'name' => 'api_secret', 'type' => 'string', 'description' => 'Secret header', 'source' => 'fixed', 'fixed_value' => 'super-secret' }
      ]
    )
  end

  before do
    confirmation_gate = instance_double(Captain::Copilot::ToolConfirmationGate, call: nil)
    allow(Captain::Copilot::ToolConfirmationGate).to receive(:new).and_return(confirmation_gate)
  end

  describe Captain::Tools::Copilot::ListCaptainCustomToolsService do
    let(:service) { described_class.new(assistant, user: admin) }

    it 'lists custom tools scoped to the current account' do
      custom_tool
      create(:captain_custom_tool, account: create(:account), title: 'Other Account')

      payload = JSON.parse(service.execute(query: 'Fetch'))

      expect(payload['action']).to eq('list_captain_custom_tools')
      expect(payload['custom_tools'].pluck('id')).to eq([custom_tool.id])
      expect(payload['custom_tools'].first).to include('slug' => custom_tool.slug, 'enabled' => true, 'param_count' => 2)
    end

    it 'rejects direct non-admin execution as defense in depth' do
      agent = create(:user, account: account)

      result = described_class.new(assistant, user: agent).execute

      expect(result).to include('Account administrator permission is required')
    end
  end

  describe Captain::Tools::Copilot::GetCaptainCustomToolService do
    let(:service) { described_class.new(assistant, user: admin) }

    it 'returns redacted tool details without raw endpoints, templates, auth secrets, or fixed params', :aggregate_failures do
      payload = JSON.parse(service.execute(tool_id: custom_tool.id))
      serialized_payload = JSON.generate(payload)

      expect(payload['action']).to eq('get_captain_custom_tool')
      expect(payload['custom_tool']).to include(
        'id' => custom_tool.id,
        'endpoint_url' => '[FILTERED]',
        'request_template' => '[FILTERED]',
        'response_template' => '[FILTERED]'
      )
      expect(payload.dig('custom_tool', 'auth_config', 'token')).to eq('[FILTERED]')
      expect(payload.dig('custom_tool', 'param_schema')).to eq('[FILTERED]')
      expect(payload.dig('custom_tool', 'param_schema_bytes')).to be_positive
      expect(serialized_payload).not_to include('api.example.test')
      expect(serialized_payload).not_to include('secret-token')
      expect(serialized_payload).not_to include('super-secret')
      expect(serialized_payload).not_to include('test_bearer_token_123')
    end

    it 'rejects cross-account custom tools' do
      other_tool = create(:captain_custom_tool, account: create(:account))

      result = service.execute(tool_id: other_tool.id)

      expect(result).to start_with('ERROR: ActiveRecord::RecordNotFound')
    end
  end

  describe Captain::Tools::Copilot::CreateCaptainCustomToolService do
    let(:service) { described_class.new(assistant, user: admin) }

    it 'creates a custom tool with sensitive output redacted' do
      payload = JSON.parse(
        service.execute(
          title: 'Create Shipment',
          description: 'Creates shipment in external system',
          endpoint_url: 'https://ship.example.test/create?api_key=secret-key',
          http_method: 'POST',
          request_template: '{ "token": "secret", "order": "{{ order_id }}" }',
          response_template: 'Status: {{ response.status }}',
          auth_type: 'api_key',
          auth_config_json: JSON.generate(name: 'X-API-Key', key: 'ship-secret', location: 'header'),
          param_schema_json: JSON.generate([{ name: 'order_id', type: 'string', description: 'Order ID', required: true }])
        )
      )

      created_tool = account.captain_custom_tools.find(payload['custom_tool']['id'])
      serialized_payload = JSON.generate(payload)

      expect(payload['action']).to eq('create_captain_custom_tool')
      expect(created_tool).to have_attributes(title: 'Create Shipment', http_method: 'POST', auth_type: 'api_key')
      expect(payload.dig('custom_tool', 'auth_config', 'key')).to eq('[FILTERED]')
      expect(serialized_payload).not_to include('ship.example.test')
      expect(serialized_payload).not_to include('ship-secret')
      expect(serialized_payload).not_to include('secret-key')
    end

    it 'redacts custom tool config from validation error output' do
      result = service.execute(
        title: 'Invalid Secret Template',
        endpoint_url: '{% https://api.example.test/secret-token %}'
      )

      expect(result).to include('[FILTERED]')
      expect(result).not_to include('api.example.test')
      expect(result).not_to include('secret-token')
    end

    it 'does not mutate until the backend confirmation gate permits execution' do
      allow(Captain::Copilot::ToolConfirmationGate).to receive(:new).and_call_original

      payload = JSON.parse(service.execute(title: 'Needs Approval', endpoint_url: 'https://pending.example.test/hook'))

      expect(payload['message']).to include('Operator confirmation is required')
      expect(account.captain_custom_tools.where(title: 'Needs Approval')).not_to exist
    end
  end

  describe 'write custom tool tools' do
    it 'updates, toggles, and deletes custom tools with redacted rollback payloads' do
      update_payload = JSON.parse(
        Captain::Tools::Copilot::UpdateCaptainCustomToolService.new(assistant, user: admin).execute(
          tool_id: custom_tool.id,
          title: 'Fetch Order Updated',
          endpoint_url: 'https://api.example.test/v2/orders?token=new-secret',
          auth_config_json: JSON.generate(token: 'new-bearer-token')
        )
      )
      status_payload = JSON.parse(
        Captain::Tools::Copilot::SetCaptainCustomToolStatusService.new(assistant, user: admin).execute(tool_id: custom_tool.id, enabled: false)
      )
      delete_payload = JSON.parse(
        Captain::Tools::Copilot::DeleteCaptainCustomToolService.new(assistant, user: admin).execute(tool_id: custom_tool.id)
      )
      serialized_payloads = JSON.generate([update_payload, status_payload, delete_payload])

      expect(update_payload['updated_fields']).to contain_exactly('title', 'endpoint_url', 'auth_config')
      expect(status_payload.dig('custom_tool', 'enabled')).to be(false)
      expect(delete_payload.dig('deleted_custom_tool', 'id')).to eq(custom_tool.id)
      expect(account.captain_custom_tools.where(id: custom_tool.id)).not_to exist
      expect(serialized_payloads).not_to include('api.example.test')
      expect(serialized_payloads).not_to include('new-secret')
      expect(serialized_payloads).not_to include('new-bearer-token')
    end
  end

  describe 'confirmation and audit redaction' do
    let(:tool_definition) { Captain::ToolRegistry.definition_for('create_captain_custom_tool').to_h }
    let(:arguments) do
      {
        endpoint_url: 'https://api.example.test/hook?token=raw-token',
        auth_config_json: JSON.generate(token: 'raw-auth-token'),
        request_template: '{ "password": "raw-password" }',
        param_schema_json: JSON.generate([{ name: 'api_secret', type: 'string', source: 'fixed', fixed_value: 'raw-fixed-secret' }])
      }
    end

    it 'redacts custom tool config before confirmation preview is persisted' do
      allow(Captain::Copilot::ToolConfirmationGate).to receive(:new).and_call_original

      copilot_thread = create(:captain_copilot_thread, account: account, assistant: assistant, user: admin)

      payload = Captain::Copilot::ToolConfirmationGate.new(
        copilot_thread: copilot_thread,
        tool_definition: tool_definition,
        arguments: arguments,
        user: admin
      ).call
      serialized_payload = JSON.generate(payload.as_json)
      persisted_preview = copilot_thread.copilot_messages.assistant_thinking.last.message.dig('confirmation_gate', 'arguments_preview')

      expect(serialized_payload).not_to include('api.example.test')
      expect(serialized_payload).not_to include('raw-auth-token')
      expect(persisted_preview).not_to include('raw-password')
      expect(persisted_preview).not_to include('raw-fixed-secret')
    end

    it 'redacts custom tool config when confirmation preview serialization falls back' do
      allow(Captain::Copilot::ToolConfirmationGate).to receive(:new).and_call_original

      gate = Captain::Copilot::ToolConfirmationGate.new(
        copilot_thread: create(:captain_copilot_thread, account: account, assistant: assistant, user: admin),
        tool_definition: tool_definition,
        arguments: arguments,
        user: admin
      )
      allow(Captain::EncodingNormalizer).to receive(:utf8).and_raise(Encoding::UndefinedConversionError.new('boom'))

      preview = gate.send(:arguments_preview)

      expect(preview).not_to include('api.example.test')
      expect(preview).not_to include('raw-auth-token')
      expect(preview).not_to include('raw-password')
      expect(preview).not_to include('raw-fixed-secret')
    end

    it 'redacts custom tool config before trace instrumentation capture', :aggregate_failures do
      service = Captain::Tools::Copilot::CreateCaptainCustomToolService.new(assistant, user: admin)

      trace_arguments = service.send(:tool_trace_arguments, arguments)
      serialized_trace_arguments = JSON.generate(trace_arguments)

      expect(serialized_trace_arguments).not_to include('api.example.test')
      expect(serialized_trace_arguments).not_to include('raw-auth-token')
      expect(serialized_trace_arguments).not_to include('raw-password')
      expect(serialized_trace_arguments).not_to include('raw-fixed-secret')
      expect(trace_arguments[:endpoint_url]).to eq('[FILTERED]')
      expect(trace_arguments[:auth_config_json]).to eq('[FILTERED]')
      expect(trace_arguments[:request_template]).to eq('[FILTERED]')
      expect(trace_arguments[:param_schema_json]).to eq('[FILTERED]')
    end

    it 'redacts custom tool config in persisted audit payloads' do
      Captain::ToolExecutionAuditService.record(
        assistant: assistant,
        scope_name: Captain::ToolAccess::SCOPE_ASSISTANT,
        tool_definition: tool_definition,
        arguments: arguments,
        result: { message: 'https://api.example.test/hook?token=raw-token' },
        user: admin
      )

      audit_payload = Enterprise::AuditLog.last.audited_changes
      serialized_payload = JSON.generate(audit_payload)

      expect(serialized_payload).not_to include('api.example.test')
      expect(serialized_payload).not_to include('raw-token')
      expect(serialized_payload).not_to include('raw-auth-token')
      expect(serialized_payload).not_to include('raw-password')
      expect(serialized_payload).not_to include('raw-fixed-secret')
    end

    it 'redacts audit serialization fallback strings' do
      bad_value_class = Class.new do
        def as_json
          raise StandardError, 'boom'
        end

        def to_s
          'https://api.example.test/hook?token=raw-token'
        end
      end
      audit_service = Captain::ToolExecutionAuditService.new(
        assistant: assistant,
        scope_name: Captain::ToolAccess::SCOPE_ASSISTANT,
        tool_definition: tool_definition,
        arguments: {},
        user: admin
      )

      serializable = audit_service.send(:serializable_value, bad_value_class.new)
      preview = audit_service.send(:serialized_preview, bad_value_class.new)

      expect(serializable).to eq('[FILTERED]')
      expect(preview).not_to include('api.example.test')
      expect(preview).not_to include('raw-token')
    end
  end

  describe 'registry exposure' do
    it 'registers custom tool admin tools as assistant-only with confirmation for writes', :aggregate_failures do
      read_tool_ids = %w[list_captain_custom_tools get_captain_custom_tool]
      write_tool_ids = %w[
        create_captain_custom_tool update_captain_custom_tool set_captain_custom_tool_status delete_captain_custom_tool
      ]

      read_tool_ids.each do |tool_id|
        definition = Captain::ToolRegistry.definition_for(tool_id)
        expect(definition.allowed_scopes).to eq([Captain::ToolAccess::SCOPE_ASSISTANT])
        expect(definition.requires_confirmation).not_to be(true)
        expect(definition.risk_level).to eq('low')
      end

      write_tool_ids.each do |tool_id|
        definition = Captain::ToolRegistry.definition_for(tool_id)
        expect(definition.allowed_scopes).to eq([Captain::ToolAccess::SCOPE_ASSISTANT])
        expect(definition.requires_confirmation).to be(true)
        expect(definition.risk_level).to eq('high')
        expect(definition.to_h[:selected_by_default]).to be(false)
      end

      expect(Captain::ToolRegistry.tools_for_scope(Captain::ToolAccess::SCOPE_AGENT).pluck(:id)).not_to include(*(read_tool_ids + write_tool_ids))
      expect(Captain::ToolRegistry.tools_for_scope(Captain::ToolAccess::SCOPE_ASSISTANT).pluck(:id)).to include(*(read_tool_ids + write_tool_ids))
    end
  end
end
# rubocop:enable RSpec/DescribeClass
