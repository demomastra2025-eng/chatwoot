require 'rails_helper'

RSpec.describe Captain::ToolRegistry do
  describe 'confirmation tools' do
    it 'registers request and resolve confirmation tools in both agent and assistant scopes' do
      agent_tools = described_class.tools_for_scope(Captain::ToolAccess::SCOPE_AGENT)
      assistant_tools = described_class.tools_for_scope(Captain::ToolAccess::SCOPE_ASSISTANT)

      expect(agent_tools.pluck(:id)).to include('request_confirmation', 'resolve_confirmation')
      expect(assistant_tools.pluck(:id)).to include('request_confirmation', 'resolve_confirmation')
    end

    it 'maps confirmation registry definitions to runtime classes with risk metadata' do
      request_definition = described_class.definition_for('request_confirmation')
      resolve_definition = described_class.definition_for('resolve_confirmation')

      expect(request_definition).to have_attributes(
        group_name: 'Confirmations',
        risk_level: 'high',
        agent_tool_class: Captain::Tools::RequestConfirmationTool,
        assistant_tool_class: Captain::Tools::Copilot::RequestConfirmationService
      )
      expect(resolve_definition).to have_attributes(
        group_name: 'Confirmations',
        risk_level: 'high',
        agent_tool_class: Captain::Tools::ResolveConfirmationTool,
        assistant_tool_class: Captain::Tools::Copilot::ResolveConfirmationService
      )
    end
  end
end
