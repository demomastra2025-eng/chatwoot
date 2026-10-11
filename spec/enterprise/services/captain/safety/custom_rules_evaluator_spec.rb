# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::Safety::CustomRulesEvaluator do
  let(:account) { instance_double(Account, id: 42) }
  let(:rule) do
    { 'id' => 'urgent_1', 'name' => 'Urgent request', 'direction' => 'input', 'instruction' => 'The customer describes an emergency.',
      'action' => 'handoff', 'enabled' => true, 'message' => 'Please contact the appropriate emergency service.' }
  end
  let(:rules) { [rule] }
  let(:account_settings) { instance_double(Captain::AccountSettings, runtime_rules: rules) }
  let(:assistant) do
    instance_double(Captain::Assistant, active?: true, account: account,
                                       config: { 'safety_settings' => { 'moderation_enabled' => false, 'custom_rules' => rules } })
  end
  let(:engine) { instance_double(Captain::Safety::CustomRulesStructuredOutputEngine, model: 'openai/gpt-6-luna', select: { rule_id: 'urgent_1' }) }
  let(:clock) { -> { 100.0 } }
  let(:evaluator) { described_class.new(engine: engine, clock: clock) }

  before { allow(Captain::AccountSettings).to receive(:new).with(account).and_return(account_settings) }

  def evaluate(text: 'I need help.', direction: 'input', context: {})
    evaluator.evaluate(assistant: assistant, direction: direction, text: text, context: context)
  end

  it 'maps a selected ID to the saved action and approved message independently of provider moderation' do
    times = [100.0, 100.25]
    timed_evaluator = described_class.new(engine: engine, clock: -> { times.shift })
    result = timed_evaluator.evaluate(assistant: assistant, direction: 'input', text: 'Help.', context: {})

    expect(result).to have_attributes(status: :matched, rule_id: 'urgent_1', action: 'handoff', message: rule['message'],
                                     direction: 'input', model: 'openai/gpt-6-luna', latency_ms: 250)
    expect(result).to be_matched
    expect(result).to be_frozen
  end

  it 'returns allowed only for an explicit none selection' do
    allow(engine).to receive(:select).and_return('{"rule_id":"none"}')

    expect(evaluate).to have_attributes(status: :allowed, rule_id: nil, action: nil, message: nil)
  end

  it 'does not invoke an engine for an inactive assistant' do
    allow(assistant).to receive(:active?).and_return(false)
    expect(engine).not_to receive(:model)
    expect(engine).not_to receive(:select)

    expect(evaluate).to have_attributes(status: :allowed, reason: :inactive_assistant, latency_ms: 0)
  end

  [[], [{ 'enabled' => false }], [{ 'direction' => 'output', 'action' => 'rewrite' }]].each do |overrides|
    it "does not invoke an engine when #{overrides.inspect} produces no enabled input rules" do
      configured = overrides.empty? ? [] : overrides.map { |override| rule.merge(override) }
      allow(account_settings).to receive(:runtime_rules).and_return(configured)
      expect(engine).not_to receive(:model)
      expect(engine).not_to receive(:select)

      expect(evaluate).to have_attributes(status: :allowed, reason: :no_enabled_rules)
    end
  end

  it 'keeps enabled rules in their configured relative order and excludes other directions and disabled conditions' do
    second = rule.merge('id' => 'second')
    output = rule.merge('id' => 'output', 'direction' => 'output', 'action' => 'rewrite')
    configured = [second, output, rule.merge('id' => 'disabled', 'enabled' => false), rule]
    allow(account_settings).to receive(:runtime_rules).and_return(configured)
    expect(engine).to receive(:select).with(model: 'openai/gpt-6-luna', rules: [second, rule], direction: 'input', text: 'I need help.', context: {})
                                    .and_return(rule_id: 'second')

    expect(evaluate.rule_id).to eq('second')
  end

  it 'fails unavailable without calling an engine for malformed persisted configuration' do
    allow(account_settings).to receive(:runtime_rules).and_return([rule.merge('enabled' => 'true')])
    expect(engine).not_to receive(:select)

    expect(evaluate).to have_attributes(status: :unavailable, reason: :invalid_configuration)
  end

  it 'does not invoke an engine for a legacy profile with no custom safety configuration' do
    allow(account_settings).to receive(:runtime_rules).and_return([])
    expect(engine).not_to receive(:model)
    expect(engine).not_to receive(:select)

    expect(evaluate).to have_attributes(status: :allowed, reason: :no_enabled_rules)
  end

  [nil, true, { text: 'Help.' }].each do |text|
    it "rejects #{text.class} text without coercion or an engine request" do
      expect(engine).not_to receive(:select)

      expect(evaluate(text: text)).to have_attributes(status: :unavailable, reason: :invalid_text)
    end
  end

  it 'accepts the text limit exactly and rejects overflow without silently truncating it' do
    boundary = 'a' * 10_000
    expect(engine).to receive(:select).with(hash_including(text: boundary)).once.and_return(rule_id: 'none')

    expect(evaluate(text: boundary)).to be_allowed
    expect(evaluate(text: boundary + 'a')).to have_attributes(status: :unavailable, reason: :text_too_long)
  end

  it 'passes only bounded factual fields and the output customer excerpt, excluding private tools and secrets' do
    allow(account_settings).to receive(:runtime_rules).and_return([rule.merge('direction' => 'output')])
    context = { conversation_status: 'pending', channel_type: 'web', locale: 'ru', source: 'playground',
                last_customer_message: 'The client asked what this quoted passage means.', api_key: 'secret',
                tool_results: { private_patient_note: 'private note' } }
    safe = context.slice(:conversation_status, :channel_type, :locale, :source, :last_customer_message).stringify_keys
    expect(engine).to receive(:select).with(hash_including(context: safe, direction: 'output')).and_return(rule_id: 'none')

    expect(evaluate(direction: 'output', context: context)).to be_allowed
  end

  it 'does not forward an output-only customer excerpt to the input engine' do
    expect(engine).to receive(:select).with(hash_including(context: {})).and_return(rule_id: 'none')

    expect(evaluate(context: { last_customer_message: 'A previous message.' })).to be_allowed
  end

  [{ locale: [] }, { source: 'x' * 121 }, 'context'].each do |context|
    it "rejects invalid factual context of type #{context.class} without an engine request" do
      expect(engine).not_to receive(:select)

      expect(evaluate(context: context)).to have_attributes(status: :unavailable, reason: :invalid_context)
    end
  end

  it 'accepts the customer excerpt limit and rejects overflow without truncation' do
    allow(account_settings).to receive(:runtime_rules).and_return([rule.merge('direction' => 'output')])
    excerpt = 'q' * 2000
    expect(engine).to receive(:select).with(hash_including(context: { 'last_customer_message' => excerpt })).once.and_return(rule_id: 'none')

    expect(evaluate(direction: 'output', context: { last_customer_message: excerpt })).to be_allowed
    expect(evaluate(direction: 'output', context: { last_customer_message: excerpt + 'q' })).to be_unavailable
  end

  [nil, {}, [], 'not JSON', { rule_id: nil }, { rule_id: 'invented' }, { rule_id: 'urgent_1', action: 'rewrite' }].each do |payload|
    it "fails unavailable for a malformed or untrusted selection #{payload.inspect}" do
      allow(engine).to receive(:select).and_return(payload)

      expect(evaluate).to have_attributes(status: :unavailable, reason: :invalid_response, action: nil, message: nil)
    end
  end

  it 'rejects a known ID when its rule belongs to another direction or is disabled' do
    configured = [rule, rule.merge('id' => 'output', 'direction' => 'output'), rule.merge('id' => 'disabled', 'enabled' => false)]
    allow(account_settings).to receive(:runtime_rules).and_return(configured)
    allow(engine).to receive(:select).and_return({ rule_id: 'output' }, { rule_id: 'disabled' })

    expect(evaluate).to be_unavailable
    expect(evaluate).to be_unavailable
  end

  it 'rejects an invalid evaluation direction without calling an engine' do
    expect(engine).not_to receive(:select)

    expect(evaluate(direction: 'both')).to have_attributes(status: :unavailable, reason: :invalid_direction)
  end

  it 'returns unavailable on provider failure and never echoes its body, token or checked text in the service log' do
    allow(engine).to receive(:select).and_raise(RubyLLM::Error, 'token=provider-secret body=patient-private-data')
    messages = []
    allow(Rails.logger).to receive(:warn) { |message| messages << message }

    expect(evaluate(text: 'private-customer-text')).to have_attributes(status: :unavailable, reason: :engine_unavailable)
    expect(messages.join).to include('code=engine_unavailable', 'error_class=RubyLLM::Error')
    expect(messages.join).not_to include('provider-secret', 'patient-private-data', 'private-customer-text')
  end

  it 'preserves a safe configuration error code without treating unsupported structured output as allowed' do
    allow(engine).to receive(:select).and_raise(Captain::Safety::CustomRulesStructuredOutputEngine::UnavailableError, :structured_output_unsupported)

    expect(evaluate).to have_attributes(status: :unavailable, reason: :structured_output_unsupported)
  end
end
