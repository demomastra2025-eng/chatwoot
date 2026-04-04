# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::Runtime::AgentRunner do
  describe '#run' do
    let(:assistant_agent) { Captain::Runtime::Agent.new(name: 'assistant_agent') }
    let(:scenario_agent) { Captain::Runtime::Agent.new(name: 'scenario_agent') }
    let(:runner) { described_class.new([assistant_agent, scenario_agent]) }

    it 'restores the current agent from persisted history with string keys' do
      runtime_runner = instance_double(Captain::Runtime::Runner, run: :ok)
      allow(Captain::Runtime::Runner).to receive(:new).and_return(runtime_runner)

      expect(runtime_runner).to receive(:run).with(
        scenario_agent,
        'continue',
        context: {
          conversation_history: [
            { 'role' => 'assistant', 'agent_name' => 'scenario_agent', 'content' => 'Handled by scenario' }
          ]
        },
        registry: {
          'assistant_agent' => assistant_agent,
          'scenario_agent' => scenario_agent
        },
        max_turns: Captain::Runtime::Runner::DEFAULT_MAX_TURNS,
        callbacks: {
          run_start: [],
          run_complete: [],
          agent_complete: [],
          tool_start: [],
          tool_complete: [],
          agent_thinking: [],
          agent_handoff: [],
          llm_call_complete: [],
          chat_created: []
        }
      ).and_return(:ok)

      expect(
        runner.run(
          'continue',
          context: {
            conversation_history: [
              { 'role' => 'assistant', 'agent_name' => 'scenario_agent', 'content' => 'Handled by scenario' }
            ]
          }
        )
      ).to eq(:ok)
    end
  end
end
