require 'rails_helper'

RSpec.describe Captain::Runtime::ConfirmedOperations do
  let(:tool) { double('action tool', name: 'create_deal', metadata: { risk_level: 'high' }) }
  let(:first_actor) { double('first actor', id: 1, agent_name: 'assistant_1', agent_tools: [tool]) }
  let(:second_actor) { double('second actor', id: 2, agent_name: 'assistant_2', agent_tools: [tool]) }
  let(:graph) { double('channel graph') }
  let(:parts) do
    [first_actor, second_actor].each_with_index.map do |actor, index|
      { 'id' => "synthetic-part-#{index}", 'version' => 2, 'executor_agent_id' => actor.id,
        'state' => 'open', 'proposed_operation' => { 'type' => 'create_deal', 'params' => { 'amount' => index + 1 } } }
    end
  end
  let(:context) do
    { state: { assistant_id: 1 }, parts: parts.deep_dup,
      agent_run_context_object: double('run context', activate: nil) }
  end

  it 'executes confirmed proposals sequentially with their exact parameters' do
    allow(graph).to receive(:find).with(1).and_return(first_actor)
    allow(graph).to receive(:find).with(2).and_return(second_actor)
    received = []
    allow(Captain::Runtime::ToolWrapper).to receive(:new) do |_tool, wrapper|
      double('wrapped tool').tap do |wrapped|
        allow(wrapped).to receive(:call) do |params|
          received << params
          wrapper.callback_manager.emit_tool_complete('create_deal', Captain::ToolResult.success(data: { id: received.size }), wrapper)
        end
      end
    end

    response = described_class.new(context: context, graph: graph).run(parts)

    expect(received).to eq([{ 'amount' => 1 }, { 'amount' => 2 }])
    expect(context[:parts].pluck('state')).to eq(%w[done done])
    expect(response.scan('Действие выполнено.').size).to eq(2)
  end
end
