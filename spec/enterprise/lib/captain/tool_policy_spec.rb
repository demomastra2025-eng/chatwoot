require 'rails_helper'

RSpec.describe Captain::ToolPolicy do
  describe '.runtime_allowed?' do
    let(:account) { create(:account) }
    let(:assistant) { create(:captain_assistant, account: account) }
    let(:user) { create(:user) }

    it 'blocks feature-gated tools when the account feature is disabled' do
      tool_definition = Captain::ToolRegistry.definition_for('create_deal').to_h

      allowed = described_class.runtime_allowed?(
        tool_definition,
        assistant: assistant,
        scope_name: Captain::ToolAccess::SCOPE_AGENT
      )

      expect(allowed).to be(false)
    end

    it 'allows feature-gated medium-risk agent tools when the required feature and runtime permission are enabled' do
      account.enable_features!('crm_deals')
      account.update!(captain_runtime: { 'agent_permissioned_tool_ids' => ['update_deal'] })
      tool_definition = Captain::ToolRegistry.definition_for('update_deal').to_h

      allowed = described_class.runtime_allowed?(
        tool_definition,
        assistant: assistant,
        scope_name: Captain::ToolAccess::SCOPE_AGENT
      )

      expect(allowed).to be(true)
    end

    it 'allows checked capability agent tools without requiring extra runtime permission policy' do
      tool_definition = Captain::ToolRegistry.definition_for('handoff').to_h

      allowed = described_class.runtime_allowed?(
        tool_definition,
        assistant: assistant,
        scope_name: Captain::ToolAccess::SCOPE_AGENT
      )

      expect(allowed).to be(true)
    end

    it 'allows note capability agent tools without requiring extra runtime permission policy' do
      tool_definition = Captain::ToolRegistry.definition_for('add_private_note').to_h

      allowed = described_class.runtime_allowed?(
        tool_definition,
        assistant: assistant,
        scope_name: Captain::ToolAccess::SCOPE_AGENT
      )

      expect(allowed).to be(true)
    end

    it 'blocks high-risk agent tools unless they are explicitly approved for autonomous execution' do
      account.enable_features!('crm_deals')
      tool_definition = Captain::ToolRegistry.definition_for('create_deal').to_h

      allowed = described_class.runtime_allowed?(
        tool_definition,
        assistant: assistant,
        scope_name: Captain::ToolAccess::SCOPE_AGENT
      )

      expect(allowed).to be(false)
    end

    it 'allows high-risk agent tools when the tool id is approved in runtime policy' do
      account.enable_features!('crm_deals')
      account.update!(captain_runtime: {
                        'agent_permissioned_tool_ids' => ['create_deal'],
                        'agent_high_risk_tool_ids' => ['create_deal']
                      })
      tool_definition = Captain::ToolRegistry.definition_for('create_deal').to_h

      allowed = described_class.runtime_allowed?(
        tool_definition,
        assistant: assistant,
        scope_name: Captain::ToolAccess::SCOPE_AGENT
      )

      expect(allowed).to be(true)
    end

    it 'allows high-risk agent tools when autonomous high-risk tools are globally enabled' do
      account.enable_features!('crm_deals')
      account.update!(captain_runtime: {
                        'agent_permissioned_tool_ids' => ['create_deal'],
                        'agent_high_risk_tools' => 'enabled'
                      })
      tool_definition = Captain::ToolRegistry.definition_for('create_deal').to_h

      allowed = described_class.runtime_allowed?(
        tool_definition,
        assistant: assistant,
        scope_name: Captain::ToolAccess::SCOPE_AGENT
      )

      expect(allowed).to be(true)
    end

    it 'treats custom agent tools as high-risk by default' do
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

      expect(allowed).to be(false)
    end

    it 'blocks assistant tools when the current user lacks the required permission' do
      custom_role = create(:custom_role, account: account, permissions: ['crm_deal_view'])
      create(:account_user, account: account, user: user, custom_role: custom_role)

      assistant_tool_definition = Captain::ToolRegistry.definition_for('update_deal').to_h
      account.enable_features!('crm_deals')

      allowed = described_class.runtime_allowed?(
        assistant_tool_definition,
        assistant: assistant,
        scope_name: Captain::ToolAccess::SCOPE_ASSISTANT,
        user: user
      )

      expect(allowed).to be(false)
    end

    it 'allows assistant tools when the current user has one of the required permissions' do
      custom_role = create(:custom_role, account: account, permissions: ['crm_deal_manage'])
      create(:account_user, account: account, user: user, custom_role: custom_role)

      assistant_tool_definition = Captain::ToolRegistry.definition_for('update_deal').to_h
      account.enable_features!('crm_deals')

      allowed = described_class.runtime_allowed?(
        assistant_tool_definition,
        assistant: assistant,
        scope_name: Captain::ToolAccess::SCOPE_ASSISTANT,
        user: user
      )

      expect(allowed).to be(true)
    end
  end
end
