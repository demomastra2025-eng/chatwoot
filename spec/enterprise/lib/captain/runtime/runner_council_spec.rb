# frozen_string_literal: true

require 'rails_helper'

# A council turn (the router chose two or three agents): the runner runs the council as the acting agent and ends the turn with the
# one reply, nothing, or a failed turn. No agent model call of its own.
RSpec.describe Captain::Runtime::Runner do
  let(:acting) { Captain::Runtime::Agent.new(name: 'assistant_1', model: 'openai/gpt-6-luna') }
  let(:parts) { [{ 'id' => 'p1', 'executor_agent_id' => 1 }, { 'id' => 'p2', 'executor_agent_id' => 2 }] }
  let(:council) { instance_double(Captain::Runtime::Council) }
  let(:events) { [] }
  let(:callbacks) do
    Captain::Runtime::CallbackManager::EVENT_TYPES.index_with { [] }.tap do |list|
      list[:run_start] << ->(name, *_) { events << [:run_start, name] }
      list[:run_complete] << ->(name, *_) { events << [:run_complete, name] }
    end
  end

  before { allow(Captain::Runtime::Council).to receive(:new).and_return(council) }

  def run_council(context: {})
    described_class.new.run_council(acting, 'сообщение', parts: parts, context: context, callbacks: callbacks, account: nil)
  end

  it 'sends the one reply of the council as the acting agent, with the callbacks of a run' do
    allow(council).to receive(:run).with(parts).and_return('Ответ консилиума')

    result = run_council

    expect(result.output).to eq(response: 'Ответ консилиума', reasoning: '')
    expect(result.error).to be_nil
    expect(result.context[:current_agent]).to eq('assistant_1')
    expect(events).to eq([[:run_start, 'assistant_1'], [:run_complete, 'assistant_1']])
    expect(Captain::Runtime::Council).to have_received(:new).with(hash_including(model: 'openai/gpt-6-luna', reassigner: nil))
  end

  it 'carries the language the owners wrote in for the logs' do
    allow(council).to receive(:run).and_return('Ответ')

    expect(run_council(context: { council_patient_language: 'kk' }).output).to eq(response: 'Ответ', reasoning: '', patient_language: 'kk')
  end

  it 'sends nothing when no part has a text of its own: the turn is suppressed, not failed' do
    allow(council).to receive(:run).and_return('')

    result = run_council

    expect(result.output).to eq(response: '', response_mode: 'suppress', reasoning: '')
    expect(result.error).to be_nil
  end

  it 'ends as a failed turn when no part has a text and a part failed technically' do
    allow(council).to receive(:run).and_return('')

    result = run_council(context: { technical_failure: { 'tool' => 'create_appointment', 'reason' => 'provider_unavailable' } })

    expect(result.error).to be_a(described_class::TechnicalFailure)
    expect(result.output).to be_nil
  end

  it 'ends with the error of the council as a result, never raising it' do
    allow(council).to receive(:run).and_raise(RuntimeError, 'boom')

    result = run_council

    expect(result.error).to be_a(RuntimeError)
    expect(events.last).to eq([:run_complete, 'assistant_1'])
  end

  it 'lets a stale run go up to the job' do
    allow(council).to receive(:run).and_raise(Captain::Conversation::ControlGenerationStaleError, 'newer message')

    expect { run_council }.to raise_error(Captain::Conversation::ControlGenerationStaleError)
  end
end
