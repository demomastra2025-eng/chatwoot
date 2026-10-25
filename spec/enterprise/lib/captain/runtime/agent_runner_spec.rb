# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::Runtime::AgentRunner do
  describe '#run' do
    let(:assistant_agent) { Captain::Runtime::Agent.new(name: 'assistant_agent') }
    let(:scenario_agent) { Captain::Runtime::Agent.new(name: 'scenario_agent') }
    let(:runner) { described_class.new([assistant_agent, scenario_agent]) }
    let(:runtime_runner) { instance_double(Captain::Runtime::Runner, run: :ok, run_council: :council) }

    before { allow(Captain::Runtime::Runner).to receive(:new).and_return(runtime_runner) }

    it 'runs the agent the router chose (context current_agent) with the registry and the callbacks of the run' do
      context = { current_agent: 'scenario_agent', conversation_history: [{ role: :assistant, agent_name: 'assistant_agent', content: 'Hi' }] }

      expect(runner.run('continue', context: context)).to eq(:ok)

      expect(runtime_runner).to have_received(:run).with(
        scenario_agent, 'continue',
        hash_including(context: context, registry: { 'assistant_agent' => assistant_agent, 'scenario_agent' => scenario_agent },
                       max_turns: Captain::Runtime::Runner::DEFAULT_MAX_TURNS,
                       callbacks: hash_including(run_start: [], llm_call_complete: [], chat_created: []))
      )
    end

    it 'never picks an agent from the history or falls back to the first agent' do
      history = [{ 'role' => 'assistant', 'agent_name' => 'scenario_agent', 'content' => 'Handled by scenario' }]

      expect { runner.run('continue', context: { conversation_history: history }) }
        .to raise_error(Captain::Runtime::Runner::AgentNotFoundError, 'No agent was chosen for this turn')
    end

    it 'runs the one agent of a channel without a choice' do
      expect(described_class.new([assistant_agent]).run('hello', context: {})).to eq(:ok)
      expect(runtime_runner).to have_received(:run).with(assistant_agent, 'hello', anything)
    end

    it 'rejects a chosen agent that is not in the registry' do
      expect { runner.run('continue', context: { current_agent: 'deleted_scenario_agent' }) }
        .to raise_error(Captain::Runtime::Runner::AgentNotFoundError, "Agent 'deleted_scenario_agent' not found in registry")
    end
  end

  describe '#run_council' do
    it 'runs the council as the acting agent with exactly the parts and the re-decision of the router' do
      acting = Captain::Runtime::Agent.new(name: 'assistant_1')
      runtime_runner = instance_double(Captain::Runtime::Runner, run_council: :council)
      allow(Captain::Runtime::Runner).to receive(:new).and_return(runtime_runner)
      parts = [{ 'id' => 'p1', 'executor_agent_id' => 1 }, { 'id' => 'p2', 'executor_agent_id' => 2 }]
      reassigner = ->(**) {}

      council = { parts: parts, acting_agent_key: 'assistant_1', reassigner: reassigner }

      expect(described_class.new([acting]).run_council('message', council: council, context: { a: 1 })).to eq(:council)
      expect(runtime_runner).to have_received(:run_council)
        .with(acting, 'message', hash_including(parts: parts, reassigner: reassigner, context: { a: 1 }))
    end
  end
end
