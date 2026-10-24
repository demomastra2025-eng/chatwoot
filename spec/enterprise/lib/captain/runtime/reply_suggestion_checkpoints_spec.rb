# frozen_string_literal: true

require 'rails_helper'

# The runtime stops a reply suggestion run between agent turns and between tool calls (cancel, deadline), and only there.
# rubocop:disable RSpec/DescribeClass
RSpec.describe 'Reply suggestion checkpoints in the runtime' do
  let(:tool_class) do
    Class.new(Captain::Runtime::Tool) do
      attr_reader :calls

      def initialize
        super
        @calls = 0
      end

      def name
        'reply_suggestion_checkpoint_spec'
      end

      def description
        'Checkpoint spec tool'
      end

      def perform(_tool_context, **_params)
        @calls += 1
        'ok'
      end
    end
  end
  let(:request_id) { SecureRandom.uuid }
  let(:far_deadline) { Process.clock_gettime(Process::CLOCK_MONOTONIC) + 600 }

  def with_cancelled_run(&)
    Captain::ReplySuggestion::RequestStore.request_cancel!(request_id)
    Captain::ReplySuggestion::RunControl.with(request_id: request_id, deadline: far_deadline, &)
  end

  describe Captain::Runtime::Runner do
    let(:runner) { described_class.new }

    it 'stops before an agent turn of a cancelled run, without counting the turn' do
      session = { current_turn: 2, max_turns: 10 }

      with_cancelled_run do
        expect { runner.send(:advance_turn!, session) }
          .to raise_error(Captain::ReplySuggestion::RunAborted) { |error| expect([error.kind, error.stage]).to eq([:cancelled, 'turn']) }
      end

      expect(session[:current_turn]).to eq(2)
    end

    it 'stops before an agent turn when the budget is spent' do
      session = { current_turn: 0, max_turns: 10 }
      expired = Process.clock_gettime(Process::CLOCK_MONOTONIC) - 1

      Captain::ReplySuggestion::RunControl.with(request_id: request_id, deadline: expired) do
        expect { runner.send(:advance_turn!, session) }
          .to raise_error(Captain::ReplySuggestion::RunAborted) { |error| expect(error.kind).to eq(:deadline) }
      end
    end

    it 'counts the turn of a live conversation as before' do
      session = { current_turn: 0, max_turns: 10 }

      runner.send(:advance_turn!, session)

      expect(session[:current_turn]).to eq(1)
    end

    it 'lets the stop out of #run instead of making it the result of the run' do
      agent = Captain::Runtime::Agent.new(name: 'agent', instructions: 'x', model: 'gpt-4.1-mini', temperature: 0.2, response_schema: nil)
      allow(runner).to receive(:build_session).and_raise(Captain::ReplySuggestion::RunAborted.new(:cancelled, 'turn'))

      expect { runner.run(agent, 'Привет') }.to raise_error(Captain::ReplySuggestion::RunAborted)
    end
  end

  describe Captain::Runtime::ToolWrapper do
    let(:tool) { tool_class.new }
    let(:context_wrapper) { Captain::Runtime::RunContext.new({ state: { captain_runtime: {} } }, callbacks: {}) }
    let(:wrapper) { described_class.new(tool, context_wrapper) }

    it 'stops before a tool call of a cancelled run, without calling the tool' do
      with_cancelled_run do
        expect { wrapper.call({}) }
          .to raise_error(Captain::ReplySuggestion::RunAborted) { |error| expect([error.kind, error.stage]).to eq([:cancelled, 'tool']) }
      end

      expect(tool.calls).to eq(0)
    end

    it 'does not turn the stop into an error of the tool for the agent to read' do
      expired = Process.clock_gettime(Process::CLOCK_MONOTONIC) - 1

      Captain::ReplySuggestion::RunControl.with(request_id: request_id, deadline: expired) do
        expect { wrapper.call({}) }.to raise_error(Captain::ReplySuggestion::RunAborted)
      end
    end

    it 'calls the tool as before while the run is neither cancelled nor out of time' do
      Captain::ReplySuggestion::RunControl.with(request_id: request_id, deadline: far_deadline) do
        wrapper.call({})
      end

      expect(tool.calls).to eq(1)
    end

    it 'calls the tool of a live conversation as before' do
      wrapper.call({})

      expect(tool.calls).to eq(1)
    end
  end

  describe 'the monitoring of an interrupted model call' do
    it 'does not count a cancel or a spent budget as an error of the call' do
      payload = {}

      Llm::ObservabilityPayload.attach_error!(payload, Captain::ReplySuggestion::RunAborted.new(:cancelled, 'tool'))

      expect(payload).to include('status' => 'aborted', 'error' => false, 'error_code' => 'suggestion_cancelled', 'reason' => 'suggestion_cancelled')
    end

    it 'names a spent budget' do
      payload = {}

      Llm::ObservabilityPayload.attach_error!(payload, Captain::ReplySuggestion::RunAborted.new(:deadline, 'turn'))

      expect(payload).to include('status' => 'aborted', 'error_code' => 'suggestion_deadline')
    end

    it 'keeps counting any other failure as an error' do
      payload = {}

      Llm::ObservabilityPayload.attach_error!(payload, ArgumentError.new('boom'))

      expect(payload).to include('status' => 'error', 'error' => true, 'error_class' => 'ArgumentError')
    end
  end
end
# rubocop:enable RSpec/DescribeClass
