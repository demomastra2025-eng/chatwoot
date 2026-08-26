require 'rails_helper'

RSpec.describe Captain::ToolPolicy do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:user) { create(:user) }

  describe '.runtime_allowed?' do
    it 'uses Firecrawl availability instead of removed account web flags' do
      account.update!(captain_runtime: { 'web_search_enabled' => false })
      assistant.update!(config: { 'tool_access' => { 'agent' => { 'enabled' => true, 'tool_ids' => ['web_search'] } } })
      allow(Captain::Tools::FirecrawlService).to receive(:configured?).and_return(true)
      tool_definition = Captain::ToolRegistry.definition_for('web_search').to_h

      expect(described_class.runtime_allowed?(
               tool_definition,
               assistant: assistant,
               scope_name: Captain::ToolAccess::SCOPE_AGENT
             )).to be(true)
    end

    it 'blocks a web tool that is disabled for the assistant' do
      assistant.update!(config: { 'tool_access' => { 'agent' => { 'enabled' => true, 'tool_ids' => [] } } })
      allow(Captain::Tools::FirecrawlService).to receive(:configured?).and_return(true)
      tool_definition = Captain::ToolRegistry.definition_for('web_search').to_h

      expect(described_class.runtime_allowed?(
               tool_definition,
               assistant: assistant,
               scope_name: Captain::ToolAccess::SCOPE_AGENT
             )).to be(false)
    end

    it 'blocks web tools when Firecrawl is unavailable' do
      account.update!(captain_runtime: { 'web_search_enabled' => true })
      allow(Captain::Tools::FirecrawlService).to receive(:configured?).and_return(false)
      tool_definition = Captain::ToolRegistry.definition_for('web_search').to_h

      expect(described_class.runtime_allowed?(
               tool_definition,
               assistant: assistant,
               scope_name: Captain::ToolAccess::SCOPE_AGENT
             )).to be(false)
    end

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

    it 'allows permissioned read-only agent tools once they are runtime-visible' do
      account.enable_features!('crm_deals')
      tool_definition = Captain::ToolRegistry.definition_for('list_deal_pipelines').to_h

      allowed = described_class.execution_allowed?(
        tool_definition,
        assistant: assistant,
        scope_name: Captain::ToolAccess::SCOPE_AGENT
      )

      expect(allowed).to be(true)
    end

    it 'allows high-risk permissioned agent tools without a second account runtime allowlist' do
      account.enable_features!('crm_deals')
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
