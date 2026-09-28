require 'rails_helper'

RSpec.describe Captain::Tools::McpTool, type: :model do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:mcp_server) { create(:captain_mcp_server, account: account) }
  let(:tool_definition) do
    {
      id: 'mcp_lookup_order',
      risk_level: 'low',
      idempotent: true,
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
  let(:tool_context) { Struct.new(:state).new({}) }

  it 'delegates execution to MCP execution service' do
    execution_service = instance_double(Captain::Mcp::ExecutionService, call: '{"ok":true}')
    allow(Captain::Mcp::ExecutionService).to receive(:new).and_return(execution_service)

    result = tool.perform(tool_context, order_id: 'ORD-1')

    expect(result).to eq('{"ok":true}')
    expect(Captain::Mcp::ExecutionService).to have_received(:new).with(
      mcp_server: mcp_server,
      tool_name: 'lookup_order',
      params: { order_id: 'ORD-1' }
    )
  end

  it 'refuses an unclassified MCP action before egress' do
    tool_definition.delete(:risk_level)
    allow(Captain::Mcp::ExecutionService).to receive(:new)

    expect(tool.perform(tool_context, order_id: 'ORD-1')).to include('provider idempotency and reconciliation contract')
    expect(Captain::Mcp::ExecutionService).not_to have_received(:new)
  end

  it 'refuses contradictory non-idempotent metadata even if risk is labelled low' do
    tool_definition[:idempotent] = false
    allow(Captain::Mcp::ExecutionService).to receive(:new)

    expect(tool.perform(tool_context, order_id: 'ORD-1')).to include('provider idempotency and reconciliation contract')
    expect(Captain::Mcp::ExecutionService).not_to have_received(:new)
  end
end
