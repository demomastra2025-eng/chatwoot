require 'rails_helper'

RSpec.describe Captain::ToolRegistry do
  describe '.tools_for_scope' do
    it 'keeps shared agent tools available in the assistant scope' do
      agent_tool_ids = described_class.tools_for_scope(Captain::ToolAccess::SCOPE_AGENT).pluck(:id)
      assistant_tool_ids = described_class.tools_for_scope(Captain::ToolAccess::SCOPE_ASSISTANT).pluck(:id)

      expect(agent_tool_ids - assistant_tool_ids).to be_empty
      expect(assistant_tool_ids).to include('search_documentation', 'faq_lookup', 'create_deal', 'create_appointment')
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
  end
end
