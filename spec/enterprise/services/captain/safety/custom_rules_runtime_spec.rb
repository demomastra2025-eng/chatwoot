require 'rails_helper'

RSpec.describe Captain::Safety::CustomRulesRuntime do
  let(:account) { build_stubbed(:account) }
  let(:assistant) { build_stubbed(:captain_assistant, account: account) }
  let(:context) { { captain_v2_current_input: 'Customer request', state: {} } }
  let(:allowed) { Captain::Safety::CustomRulesEvaluator::Result.new(status: :allowed) }
  let(:matched) do
    Captain::Safety::CustomRulesEvaluator::Result.new(status: :matched, direction: 'output', rule_id: 'no_dead_end', action: 'rewrite')
  end
  let(:response) { { 'response' => 'I do not know.', 'artifact_ids' => [12] } }
  let(:rewriter) { instance_double(Captain::Safety::ResponseRewriteEngine) }

  before do
    allow(Llm::EventBus).to receive(:publish)
    allow(Captain::Safety::CustomRulesEvaluator).to receive(:evaluate).and_return(allowed)
    allow(Captain::Safety::ResponseRewriteEngine).to receive(:new).and_return(rewriter)
    allow(Llm::SafetyPolicy).to receive(:check!)
  end

  it 'checks one customer input once across agent activations and checks new input separately' do
    2.times { described_class.check_input!(assistant: assistant, context: context) }
    described_class.check_input!(assistant: assistant, context: context, text: 'A different request')
    other = build_stubbed(:captain_assistant, account: account)
    described_class.check_input!(assistant: other, context: context)

    expect(Captain::Safety::CustomRulesEvaluator).to have_received(:evaluate).exactly(2).times
  end

  it 'does not reuse a decision after an enabled rule changes in the same run' do
    described_class.check_input!(assistant: assistant, context: context)
    account.settings[Captain::AccountSettings::KEY] = { 'safety' => { 'custom_rules' => [{ 'id' => 'new_rule' }] } }
    described_class.check_input!(assistant: assistant, context: context)
    expect(Captain::Safety::CustomRulesEvaluator).to have_received(:evaluate).twice
  end

  it 'stops before agent work when the input checker is unavailable' do
    unavailable = Captain::Safety::CustomRulesEvaluator::Result.new(status: :unavailable, direction: 'input', reason: :engine_unavailable)
    allow(Captain::Safety::CustomRulesEvaluator).to receive(:evaluate).and_return(unavailable)
    expect(rewriter).not_to receive(:rewrite)
    expect { described_class.check_input!(assistant: assistant, context: context) }
      .to raise_error(described_class::HandoffRequired) { |error| expect(error.assistant_id).to eq(assistant.id) }
  end

  it 'does not truncate the checked input or include image URLs in the classifier text' do
    long_text = 'x' * 10_001
    input = [{ type: 'text', text: long_text }, { type: 'image_url', image_url: { url: 'private-image-url' } }]
    described_class.check_input!(assistant: assistant, context: context, text: input)
    expect(Captain::Safety::CustomRulesEvaluator).to have_received(:evaluate).with(hash_including(text: long_text))
  end

  it 'does not rewrite or alter an allowed answer' do
    expect(rewriter).not_to receive(:rewrite)
    expect(described_class.check_output!(assistant: assistant, context: context, response: response)).to equal(response)
  end

  it 'repairs only the text once, checks the whole policy again, and preserves existing artifact selection' do
    allow(Captain::Safety::CustomRulesEvaluator).to receive(:evaluate).and_return(matched, allowed)
    allow(rewriter).to receive(:rewrite).and_return('Which delivery date should I check?')

    result = described_class.check_output!(assistant: assistant, context: context, response: response)
    expect(result).to include('response' => 'Which delivery date should I check?', 'artifact_ids' => [12])
    expect(response['response']).to eq('I do not know.')
    expect(rewriter).to have_received(:rewrite).once
    expect(Captain::Safety::CustomRulesEvaluator).to have_received(:evaluate)
      .with(hash_including(direction: 'output', text: 'Which delivery date should I check?'))
    expect(Llm::SafetyPolicy).to have_received(:check!).with(hash_including(content: 'Which delivery date should I check?'))
  end

  it 'hands off instead of retrying a second repair' do
    allow(Captain::Safety::CustomRulesEvaluator).to receive(:evaluate).and_return(matched)
    allow(rewriter).to receive(:rewrite).and_return('I still do not know.')
    expect { described_class.check_output!(assistant: assistant, context: context, response: response) }
      .to raise_error(described_class::HandoffRequired)
    expect(rewriter).to have_received(:rewrite).once
  end

  it 'does not send a replacement when its second check is unavailable' do
    unavailable = Captain::Safety::CustomRulesEvaluator::Result.new(status: :unavailable, reason: :engine_unavailable)
    allow(Captain::Safety::CustomRulesEvaluator).to receive(:evaluate).and_return(matched, unavailable)
    allow(rewriter).to receive(:rewrite).and_return('A possible answer')
    expect { described_class.check_output!(assistant: assistant, context: context, response: response) }
      .to raise_error(described_class::HandoffRequired)
  end

  it 'never attempts text repair for a blocking rule' do
    blocked = Captain::Safety::CustomRulesEvaluator::Result.new(status: :matched, action: 'block')
    allow(Captain::Safety::CustomRulesEvaluator).to receive(:evaluate).and_return(blocked)
    expect(rewriter).not_to receive(:rewrite)
    expect { described_class.check_output!(assistant: assistant, context: context, response: response) }
      .to raise_error(described_class::HandoffRequired)
  end

  it 'does not bypass the platform safety check with a repaired answer' do
    allow(Captain::Safety::CustomRulesEvaluator).to receive(:evaluate).and_return(matched, allowed)
    allow(rewriter).to receive(:rewrite).and_return('Unsafe replacement')
    allow(Llm::SafetyPolicy).to receive(:check!).and_raise(
      Llm::SafetyPolicy::UnsafeContentError.new(feature: :assistant, stage: :output, reason: :sensitive_info)
    )
    expect { described_class.check_output!(assistant: assistant, context: context, response: response) }
      .to raise_error(Llm::SafetyPolicy::UnsafeContentError)
  end
end
