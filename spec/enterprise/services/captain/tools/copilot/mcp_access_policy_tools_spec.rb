# frozen_string_literal: true

require 'rails_helper'

# rubocop:disable RSpec/DescribeClass
RSpec.describe 'Captain MCP access policy copilot tools' do
  let(:account) do
    create(:account).tap do |record|
      record.mcp_access = {
        'enabled' => true,
        'sources' => {
          'captain' => true,
          'openapi_read' => true,
          'openapi_write' => false
        },
        'max_risk_level' => 'low',
        'require_confirmation_for_mutations' => true,
        'allowed_groups' => ['captain:Knowledge'],
        'blocked_groups' => [],
        'allowed_tool_ids' => [],
        'blocked_tool_ids' => [],
        'allowed_openapi_operation_ids' => [],
        'blocked_openapi_operation_ids' => []
      }
      record.save!
    end
  end
  let(:assistant) { create(:captain_assistant, account: account, usage_mode: 'internal_assistant') }
  let(:admin) { create(:user, :administrator, account: account) }

  before do
    confirmation_gate = instance_double(Captain::Copilot::ToolConfirmationGate, call: nil)
    allow(Captain::Copilot::ToolConfirmationGate).to receive(:new).and_return(confirmation_gate)
  end

  describe Captain::Tools::Copilot::GetMcpAccessPolicyService do
    let(:service) { described_class.new(assistant, user: admin) }

    it 'returns normalized MCP access policy and catalog summary for account administrators' do
      payload = JSON.parse(service.execute)

      expect(payload['action']).to eq('get_mcp_access_policy')
      expect(payload.dig('mcp', 'mcp_access')).to include(
        'enabled' => true,
        'max_risk_level' => 'low',
        'require_confirmation_for_mutations' => true,
        'allowed_groups' => ['captain:Knowledge']
      )
      expect(payload.dig('mcp', 'mcp_access', 'sources')).to include(
        'captain' => true,
        'openapi_read' => true,
        'openapi_write' => false
      )
      expect(payload.dig('mcp', 'permissions', 'manage')).to be(true)
      expect(payload.dig('mcp', 'summary')).to include('total_tools', 'enabled_tools')
      expect(payload.dig('mcp', 'tools')).to eq([])
    end

    it 'can include the visible tool catalog when explicitly requested' do
      payload = JSON.parse(service.execute(include_tools: true))

      expect(payload.dig('mcp', 'tools')).to be_an(Array)
      expect(payload.dig('mcp', 'tools').size).to be_positive
    end

    it 'rejects direct non-admin execution as defense in depth' do
      agent = create(:user, account: account)

      result = described_class.new(assistant, user: agent).execute

      expect(result).to include('Account administrator permission is required')
    end
  end

  describe Captain::Tools::Copilot::UpdateMcpAccessPolicyService do
    let(:service) { described_class.new(assistant, user: admin) }

    it 'updates MCP access policy fields through the native account settings model' do
      payload = JSON.parse(
        service.execute(
          enabled: false,
          max_risk_level: 'medium',
          require_confirmation_for_mutations: false,
          captain_tools_enabled: true,
          openapi_read_tools_enabled: true,
          openapi_write_tools_enabled: true,
          allowed_groups: ['captain:Account', 'openapi:Contacts'],
          blocked_groups: ['captain:Payments'],
          allowed_tool_ids: ['get_workspace_profile'],
          blocked_tool_ids: ['update_workspace_profile'],
          allowed_openapi_operation_ids: ['listContacts'],
          blocked_openapi_operation_ids: ['deleteContact']
        )
      )

      account.reload
      expect(payload['action']).to eq('update_mcp_access_policy')
      expect(payload['updated_fields']).to include(
        'enabled',
        'max_risk_level',
        'require_confirmation_for_mutations',
        'sources.openapi_write',
        'allowed_groups',
        'blocked_openapi_operation_ids'
      )
      expect(account.mcp_access).to include(
        'enabled' => false,
        'max_risk_level' => 'medium',
        'require_confirmation_for_mutations' => false,
        'allowed_groups' => ['captain:Account', 'openapi:Contacts'],
        'blocked_groups' => ['captain:Payments'],
        'allowed_tool_ids' => ['get_workspace_profile'],
        'blocked_tool_ids' => ['update_workspace_profile'],
        'allowed_openapi_operation_ids' => ['listContacts'],
        'blocked_openapi_operation_ids' => ['deleteContact']
      )
      expect(account.mcp_access['sources']).to include(
        'captain' => true,
        'openapi_read' => true,
        'openapi_write' => true
      )
    end

    it 'updates MCP access through the simple basic/full access mode preset' do
      payload = JSON.parse(service.execute(access_mode: 'full'))

      account.reload
      expect(payload['updated_fields']).to include('access_mode')
      expect(account.mcp_access).to include(
        'enabled' => true,
        'max_risk_level' => 'custom',
        'require_confirmation_for_mutations' => false,
        'allowed_groups' => [],
        'blocked_groups' => []
      )
      expect(account.mcp_access['sources']).to include(
        'captain' => true,
        'openapi_read' => true,
        'openapi_write' => true
      )
    end

    it 'rejects unsupported fields instead of passing arbitrary settings through' do
      result = service.execute(raw_settings: { enabled: false })

      expect(result).to include('Unsupported MCP access fields: raw_settings')
      expect(account.reload.mcp_access['enabled']).to be(true)
    end

    it 'rejects invalid risk levels without mutating the policy' do
      result = service.execute(max_risk_level: 'root')

      expect(result).to include('max_risk_level must be one of: low, medium, high, custom')
      expect(account.reload.mcp_access['max_risk_level']).to eq('low')
    end

    it 'rejects direct non-admin execution as defense in depth' do
      agent = create(:user, account: account)

      result = described_class.new(assistant, user: agent).execute(max_risk_level: 'high')

      expect(result).to include('Account administrator permission is required')
      expect(account.reload.mcp_access['max_risk_level']).to eq('low')
    end

    it 'does not mutate until the backend confirmation gate permits execution' do
      allow(Captain::Copilot::ToolConfirmationGate).to receive(:new).and_call_original

      payload = JSON.parse(service.execute(max_risk_level: 'high'))

      expect(payload['message']).to include('Operator confirmation is required')
      expect(payload.dig('data', 'confirmation_required')).to be(true)
      expect(account.reload.mcp_access['max_risk_level']).to eq('low')
    end
  end

  describe 'registry exposure' do
    it 'exposes MCP access policy tools only to the operator assistant scope' do
      get_definition = Captain::ToolRegistry.definition_for('get_mcp_access_policy')
      update_definition = Captain::ToolRegistry.definition_for('update_mcp_access_policy')
      tool_ids = %w[get_mcp_access_policy update_mcp_access_policy]

      expect(get_definition.allowed_scopes).to eq([Captain::ToolAccess::SCOPE_ASSISTANT])
      expect(get_definition.to_h).to include(risk_level: 'low', idempotent: true, selected_by_default: false)
      expect(update_definition.allowed_scopes).to eq([Captain::ToolAccess::SCOPE_ASSISTANT])
      expect(update_definition.to_h).to include(risk_level: 'high', requires_confirmation: true, selected_by_default: false)
      expect(Captain::ToolRegistry.tools_for_scope(Captain::ToolAccess::SCOPE_AGENT).pluck(:id)).not_to include(*tool_ids)
      expect(Captain::ToolRegistry.tools_for_scope(Captain::ToolAccess::SCOPE_ASSISTANT).pluck(:id)).to include(*tool_ids)
    end
  end
end
# rubocop:enable RSpec/DescribeClass
