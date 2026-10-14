# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::OpenRouterRuntime, '#decide' do
  let(:account) { create(:account) }
  let(:model) { 'microsoft/microsoft-decision-1' }
  let(:served_model) { 'microsoft/microsoft-decision-1-20261009' }
  let(:api_key) { 'synthetic-decision-runtime-key' }
  let(:endpoint) { 'https://openrouter.example/api/alpha/decisions' }
  let(:state) do
    { 'outcome' => 'completion',
      'messages' => [{ 'role' => 'customer', 'content' => 'SYNTHETIC_PRIVATE_CUSTOMER_TEXT' }] }
  end
  let(:criteria) do
    { 'synthetic_completed_answer' => 'SYNTHETIC_PRIVATE_CRITERION: the question was answered.',
      'other' => 'No supported reason is established.' }
  end
  let(:instructions) { 'SYNTHETIC_PRIVATE_INSTRUCTIONS: select a reason using the supplied facts.' }
  let(:response_body) do
    { id: 'gen-dec-runtime-synthetic', model: served_model, provider: 'Azure',
      answers: { reason: { choice: 'synthetic_completed_answer', confidence: 0.9 } },
      usage: { input_tokens: 100, output_tokens: 1, total_tokens: 101, cost: 0.0000042,
               untrusted: 'SYNTHETIC_PRIVATE_PROVIDER_TEXT' } }
  end

  before do
    allow(Llm::Config).to receive(:api_key).and_call_original
    allow(Llm::Config).to receive(:api_key).with('openrouter', account: account).and_return(api_key)
    allow(Llm::Config).to receive(:api_base).and_call_original
    allow(Llm::Config).to receive(:api_base).with('openrouter', account: account).and_return('https://openrouter.example/api/v1')
  end

  def decision_request(**overrides)
    Llm::FeatureRequest.new(feature: :outcome_classification, account: account, model: model, input: state,
                            options: { decision_criteria: criteria, decision_instructions: instructions }, **overrides)
  end

  def private_values
    [state['messages'].first['content'], criteria['synthetic_completed_answer'], instructions,
     'synthetic_completed_answer', 'SYNTHETIC_PRIVATE_PROVIDER_TEXT', api_key]
  end

  it 'uses the same Decisions transport for language detection' do
    language_model = 'openai/gpt-6-luna-decisions'
    stub_request(:post, endpoint).to_return(status: 200, body: response_body.merge(
      model: language_model, answers: { reason: { choice: 'kk', confidence: 0.9 } }
    ).to_json)

    request = decision_request(
      feature: :language_detection, model: language_model,
      input: { messages: '1. Fake patient words' },
      options: { decision_criteria: { 'ru' => 'Russian.', 'kk' => 'Kazakh.' }, decision_instructions: 'Choose a language.' }
    )
    result = Llm::Runtime.decide(request)

    expect(result.choice).to eq('kk')
  end

  it 'uses the native Decisions transport for custom guardrails without recording checked text' do
    guardrail_model = 'openai/gpt-6-luna-decisions'
    checked_text = 'Fake appointment question.'
    guardrail_criteria = { 'rule_one' => 'The reply promises a fixed time.', 'none' => 'No rule matches.' }
    stub = stub_request(:post, endpoint).with do |http_request|
      body = JSON.parse(http_request.body)
      expect(body).to include(
        'model' => guardrail_model,
        'state' => { 'candidate_text' => checked_text, 'factual_context' => { 'locale' => 'ru' } },
        'questions' => { 'reason' => { 'type' => 'choice', 'criteria' => guardrail_criteria,
                                       'instructions' => 'Choose the first matching rule ID.' } }
      )
      true
    end.to_return(status: 200, body: response_body.merge(
      model: guardrail_model, answers: { reason: { choice: 'rule_one', confidence: 0.9 } }
    ).to_json)

    request = decision_request(
      feature: :custom_guardrail, model: guardrail_model,
      input: { candidate_text: checked_text, factual_context: { locale: 'ru' } },
      options: { decision_criteria: guardrail_criteria,
                 decision_instructions: 'Choose the first matching rule ID.' }
    )

    expect(Llm::Runtime.decide(request).choice).to eq('rule_one')
    expect(stub).to have_been_requested.once
    expect(LlmEvent.find_by!(account_id: account.id, event_name: 'llm.decision.complete').payload.to_json).not_to include(checked_text)
  end

  it 'applies provider preferences and mandatory ZDR before sending the decision state' do
    request = decision_request(
      privacy_profile: 'zdr_required',
      runtime_preferences: {
        openrouter_provider_order: ['azure'], openrouter_provider_only: ['azure'],
        openrouter_preferred_max_latency: 5, openrouter_allow_fallbacks: true,
        openrouter_zdr: false, openrouter_data_collection: 'allow'
      }
    )
    stub = stub_request(:post, endpoint).with do |http_request|
      body = JSON.parse(http_request.body)
      expect(body).to include(
        'model' => model, 'state' => state,
        'questions' => { 'reason' => { 'type' => 'choice', 'criteria' => criteria, 'instructions' => instructions } },
        'provider' => include('order' => ['azure'], 'only' => ['azure'], 'preferred_max_latency' => 5,
                              'require_parameters' => true, 'allow_fallbacks' => false, 'data_collection' => 'deny', 'zdr' => true)
      )
      expect(body).not_to include('messages', 'prompt', 'tools')
      expect(http_request.headers.transform_keys(&:downcase)).to include('authorization' => "Bearer #{api_key}")
      true
    end.to_return(status: 200, body: response_body.to_json)

    result = Llm::Runtime.decide(request)

    expect(result).to have_attributes(choice: 'synthetic_completed_answer', model: served_model, provider: 'Azure')
    expect(stub).to have_been_requested.once
  end

  it 'keeps response caching off on the native endpoint even when the caller requests it' do
    request = decision_request(options: {
                                 decision_criteria: criteria, decision_instructions: instructions,
                                 openrouter_response_cache: { enabled: true, ttl: 60, clear: true }
                               })
    stub = stub_request(:post, endpoint).with do |http_request|
      headers = http_request.headers.transform_keys(&:downcase)
      expect(headers).to include('http-referer', 'x-openrouter-title')
      expect(headers.keys.grep(/\Ax-openrouter-cache/)).to be_empty
      true
    end.to_return(status: 200, body: response_body.to_json)

    Llm::Runtime.decide(request)

    expect(stub).to have_been_requested.once
    expect(LlmEvent.find_by!(account_id: account.id, event_name: 'llm.decision.complete').payload).to include(
      'openrouter_native_endpoint' => '/alpha/decisions',
      'openrouter_response_cache' => 'disabled',
      'openrouter_response_cache_reason' => 'not_requested'
    )
  end

  it 'publishes a native decision event without exposing the state, instructions, answer or key' do
    events = []
    subscriber = ActiveSupport::Notifications.subscribe(/\Allm\.(chat|decision)\.complete\z/) do |*args|
      events << ActiveSupport::Notifications::Event.new(*args)
    end
    request = decision_request(observability: {
                                 trace_id: 'synthetic-decision-trace', source: 'outcome_classification',
                                 messages: state['messages'], input: state, prompt: instructions,
                                 answer: 'synthetic_completed_answer', api_key: api_key,
                                 metadata: { messages: state['messages'], prompt: instructions, api_key: api_key }
                               })
    stub_request(:post, endpoint).to_return(status: 200, body: response_body.to_json)

    result = Llm::Runtime.decide(request)

    expect(result.choice).to eq('synthetic_completed_answer')
    expect(events.map(&:name)).to eq(['llm.decision.complete'])
    expect(events.first.payload).to include(
      'canonical_event_name' => 'llm.decision.complete', 'feature' => 'outcome_classification',
      'provider' => 'openrouter', 'runtime_mode' => 'openrouter_runtime', 'status' => 'success',
      'trace_id' => 'synthetic-decision-trace', 'requested_model' => model, 'actual_model' => served_model,
      'endpoint_provider' => 'Azure', 'output_type' => 'decision', 'openrouter_native_endpoint' => '/alpha/decisions'
    )
    expect(events.first.payload).not_to include('state', 'messages', 'input', 'prompt', 'answer', 'answers', 'api_key')
    expect(events.first.payload.to_json).not_to include(*private_values)
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  it 'records one account-scoped event and usage entry with the served model and reported cost without generation enrichment' do
    stub_request(:post, endpoint).to_return(status: 200, body: response_body.to_json)
    expect(Internal::FetchOpenRouterGenerationMetadataJob).not_to receive(:perform_later)

    expect { Llm::Runtime.decide(decision_request) }
      .to change { LlmEvent.where(account_id: account.id, event_name: 'llm.decision.complete').count }.by(1)
      .and change { LlmUsageEvent.where(account_id: account.id, event_name: 'llm.decision.complete').count }.by(1)

    event = LlmEvent.find_by!(account_id: account.id, event_name: 'llm.decision.complete')
    usage = LlmUsageEvent.find_by!(llm_event_id: event.id)
    expect(usage).to have_attributes(
      account_id: account.id, event_name: 'llm.decision.complete', feature: 'outcome_classification',
      provider: 'openrouter', actual_provider: 'Azure', requested_model: model, actual_model: served_model,
      generation_id: 'gen-dec-runtime-synthetic', status: 'success',
      prompt_tokens: 100, completion_tokens: 1, total_tokens: 101
    )
    expect(usage.estimated_cost.to_f).to eq(0.0000042)
    expect(event.estimated_cost.to_f).to eq(0.0000042)
    expect([event.attributes, usage.attributes].to_json).not_to include(*private_values)
  end

  it 'propagates an evaluator refusal before HTTP or a completion event can occur' do
    request = decision_request
    # Current stored budget policies are advisory; exercise the runtime's refusal boundary explicitly.
    expect(Llm::BudgetEvaluator).to receive(:evaluate!).with(request: request, model: model)
                                                       .and_raise(StandardError, 'synthetic budget refusal')

    expect { Llm::Runtime.decide(request) }.to raise_error(StandardError, 'synthetic budget refusal')
    expect(a_request(:post, endpoint)).not_to have_been_made
    expect(LlmEvent.where(account_id: account.id, event_name: 'llm.decision.complete')).to be_empty
    expect(LlmUsageEvent.where(account_id: account.id)).to be_empty
  end

  %i[captain_agent moderation].each do |feature|
    it "rejects #{feature} before invoking the decision client" do
      expect(Llm::OpenRouterDecisionClient).not_to receive(:choose)
      expect(Llm::BudgetEvaluator).not_to receive(:evaluate!)

      expect { Llm::Runtime.decide(decision_request(feature: feature)) }
        .to raise_error(ArgumentError, 'Decisions is unavailable for this feature.')
      expect(a_request(:post, endpoint)).not_to have_been_made
      expect(LlmUsageEvent.where(account_id: account.id)).to be_empty
    end
  end

  it 'records an unavailable decision as an error without retaining the provider body or inventing an answer' do
    stub = stub_request(:post, endpoint).to_return(
      status: 503, body: { error: { message: "#{api_key} SYNTHETIC_PRIVATE_PROVIDER_TEXT #{instructions}" } }.to_json
    )

    expect { Llm::Runtime.decide(decision_request) }.to raise_error do |error|
      expect(error.class.name).to eq('Llm::OpenRouterDecisionClient::Error')
      expect(error.message).to eq('OpenRouter decision request failed (HTTP 503).')
    end

    event = LlmEvent.find_by!(account_id: account.id, event_name: 'llm.decision.complete')
    usage = LlmUsageEvent.find_by!(llm_event_id: event.id)
    expect(stub).to have_been_requested.once
    expect(usage).to have_attributes(status: 'error', requested_model: model, actual_model: nil)
    expect(event).to have_attributes(status: 'error', error: true)
    expect([event.attributes, usage.attributes].to_json).not_to include(*private_values)
  end
end
