require 'rails_helper'

RSpec.describe Captain::Tools::Copilot::McpTool do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:mcp_server) { create(:captain_mcp_server, account: account) }
  let(:tool_definition) do
    {
      id: 'mcp_lookup_order',
      description: 'Lookup order in MCP',
      mcp_tool_name: 'lookup_order',
      input_schema: {
        'type' => 'object',
        'properties' => {
          'order_id' => { 'type' => 'string', 'description' => 'Order ID' }
        },
        'required' => ['order_id']
      }
    }
  end
  let(:tool) { described_class.new(assistant, mcp_server, tool_definition) }

  it 'delegates copilot execution to MCP execution service' do
    execution_service = instance_double(Captain::Mcp::ExecutionService, call: '{"ok":true}')
    allow(Captain::Mcp::ExecutionService).to receive(:new).and_return(execution_service)

    result = tool.execute(order_id: 'ORD-1')

    expect(result).to eq('{"ok":true}')
    expect(Captain::Mcp::ExecutionService).to have_received(:new).with(
      mcp_server: mcp_server,
      tool_name: 'lookup_order',
      params: { order_id: 'ORD-1' }
    )
  end
end
