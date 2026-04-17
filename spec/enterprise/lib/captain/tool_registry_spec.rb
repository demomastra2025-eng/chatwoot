require 'rails_helper'

RSpec.describe Captain::ToolRegistry do
  describe '.tools_for_scope' do
    it 'keeps shared agent tools available in the assistant scope' do
      agent_tool_ids = described_class.tools_for_scope(Captain::ToolAccess::SCOPE_AGENT).pluck(:id)
      assistant_tool_ids = described_class.tools_for_scope(Captain::ToolAccess::SCOPE_ASSISTANT).pluck(:id)

      expect(agent_tool_ids - assistant_tool_ids).to be_empty
      expect(assistant_tool_ids).to include('search_documentation', 'faq_lookup', 'create_deal', 'create_appointment', 'create_touch')
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
    end

    it 'marks capability tools that are controlled through assistant settings checkboxes' do
      handoff = described_class.tools_for_scope(Captain::ToolAccess::SCOPE_AGENT).find { |tool| tool[:id] == 'handoff' }
      add_private_note = described_class.tools_for_scope(Captain::ToolAccess::SCOPE_ASSISTANT).find { |tool| tool[:id] == 'add_private_note' }

      expect(handoff).to include(id: 'handoff', capability_tool: true)
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
end
