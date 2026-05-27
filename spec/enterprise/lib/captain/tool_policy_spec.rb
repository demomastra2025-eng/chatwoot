require 'rails_helper'

RSpec.describe Captain::ToolPolicy do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:user) { create(:user) }

  describe '.runtime_allowed?' do
    it 'allows agent tools when their required feature is enabled' do
      account.enable_features!('crm_deals')
      tool_definition = Captain::ToolRegistry.definition_for('create_deal').to_h

      allowed = described_class.runtime_allowed?(
        tool_definition,
        assistant: assistant,
        scope_name: Captain::ToolAccess::SCOPE_AGENT
      )

      expect(allowed).to be(true)
    end

    it 'does not block explicit prompt references once the feature exists' do
      account.enable_features!('crm_deals')
      assistant.update!(description: 'Use [Create Deal](tool://create_deal) when asked.')
      tool_definition = Captain::ToolRegistry.definition_for('create_deal').to_h

      allowed = described_class.runtime_allowed?(
        tool_definition,
        assistant: assistant,
        scope_name: Captain::ToolAccess::SCOPE_AGENT
      )

      expect(allowed).to be(true)
    end

    it 'allows custom agent tools without separate high-risk runtime approval' do
      tool_definition = {
        id: 'custom_external_mutation',
        allowed_scopes: [Captain::ToolAccess::SCOPE_AGENT],
        risk_level: 'custom'
      }

      allowed = described_class.runtime_allowed?(
        tool_definition,
        assistant: assistant,
        scope_name: Captain::ToolAccess::SCOPE_AGENT
      )

      expect(allowed).to be(true)
    end

    it 'allows assistant tools without separate per-user runtime permission gating' do
      custom_role = create(:custom_role, account: account, permissions: ['crm_deal_view'])
      create(:account_user, account: account, user: user, custom_role: custom_role)
      account.enable_features!('crm_deals')
      assistant_tool_definition = Captain::ToolRegistry.definition_for('update_deal').to_h

      allowed = described_class.runtime_allowed?(
        assistant_tool_definition,
        assistant: assistant,
        scope_name: Captain::ToolAccess::SCOPE_ASSISTANT,
        user: user
      )

      expect(allowed).to be(true)
    end

    it 'still blocks assistant-only tools outside the allowed scope' do
      tool_definition = Captain::ToolRegistry.definition_for('create_webhook').to_h

      allowed = described_class.runtime_allowed?(
        tool_definition,
        assistant: assistant,
        scope_name: Captain::ToolAccess::SCOPE_AGENT
      )

      expect(allowed).to be(false)
    end
  end

  describe '.execution_allowed?' do
    it 'allows low-risk capability agent tools without extra runtime approval' do
      tool_definition = Captain::ToolRegistry.definition_for('faq_lookup').to_h

      allowed = described_class.execution_allowed?(
        tool_definition,
        assistant: assistant,
        scope_name: Captain::ToolAccess::SCOPE_AGENT
      )

      expect(allowed).to be(true)
    end

    it 'blocks high-risk permissioned agent tools until account runtime policy allows them' do
      account.enable_features!('crm_deals')
      tool_definition = Captain::ToolRegistry.definition_for('create_deal').to_h

      allowed = described_class.execution_allowed?(
        tool_definition,
        assistant: assistant,
        scope_name: Captain::ToolAccess::SCOPE_AGENT
      )

      expect(allowed).to be(false)
      expect(described_class.execution_error_message(
               tool_definition,
               assistant: assistant,
               scope_name: Captain::ToolAccess::SCOPE_AGENT
             )).to eq('Tool permission is not available for the current operator or agent runtime')
    end

    it 'allows high-risk permissioned agent tools when both permission and risk policy allow them' do
      account.enable_features!('crm_deals')
      account.update!(captain_runtime: {
                        'agent_permissioned_tool_ids' => ['create_deal'],
                        'agent_high_risk_tool_ids' => ['create_deal']
                      })
      tool_definition = Captain::ToolRegistry.definition_for('create_deal').to_h

      allowed = described_class.execution_allowed?(
        tool_definition,
        assistant: assistant,
        scope_name: Captain::ToolAccess::SCOPE_AGENT
      )

      expect(allowed).to be(true)
    end

    it 'blocks assistant-scope tools when the current operator lacks required permissions' do
      custom_role = create(:custom_role, account: account, permissions: ['crm_deal_view'])
      create(:account_user, account: account, user: user, custom_role: custom_role)
      account.enable_features!('crm_deals')
      tool_definition = Captain::ToolRegistry.definition_for('create_deal').to_h

      allowed = described_class.execution_allowed?(
        tool_definition,
        assistant: assistant,
        scope_name: Captain::ToolAccess::SCOPE_ASSISTANT,
        user: user
      )

      expect(allowed).to be(false)
    end

    it 'allows assistant-scope tools when the current operator has a required permission' do
      custom_role = create(:custom_role, account: account, permissions: ['crm_deal_manage'])
      create(:account_user, account: account, user: user, custom_role: custom_role)
      account.enable_features!('crm_deals')
      tool_definition = Captain::ToolRegistry.definition_for('create_deal').to_h

      allowed = described_class.execution_allowed?(
        tool_definition,
        assistant: assistant,
        scope_name: Captain::ToolAccess::SCOPE_ASSISTANT,
        user: user
      )

      expect(allowed).to be(true)
    end
  end
end
