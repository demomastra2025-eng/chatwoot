require 'rails_helper'

RSpec.describe Captain::ToolRegistry do
  it 'exposes one bounded customer task tool to agents and keeps broad task tools assistant-only' do
    customer_tasks = described_class.definition_for('customer_tasks')
    broad_task_tool_ids = %w[
      get_task search_tasks list_task_custom_fields get_task_timeline create_task update_task change_task_status
    ]

    expect(customer_tasks.allowed_scopes).to eq([Captain::ToolAccess::SCOPE_AGENT])
    expect(customer_tasks.agent_tool_class).to eq(Captain::Tools::CustomerTasksTool)
    broad_task_tool_ids.each do |tool_id|
      definition = described_class.definition_for(tool_id)
      expect(definition.allowed_scopes).to eq([Captain::ToolAccess::SCOPE_ASSISTANT])
      expect(definition.agent_tool_class).to be_nil
    end
  end
end
