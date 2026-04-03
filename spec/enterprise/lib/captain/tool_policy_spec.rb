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

    it 'allows feature-gated tools when the required account feature is enabled' do
      account.enable_features!('crm_deals')
      tool_definition = Captain::ToolRegistry.definition_for('create_deal').to_h

      allowed = described_class.runtime_allowed?(
        tool_definition,
        assistant: assistant,
        scope_name: Captain::ToolAccess::SCOPE_AGENT
      )

      expect(allowed).to be(true)
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
