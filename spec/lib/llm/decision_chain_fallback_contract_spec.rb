# frozen_string_literal: true

require 'rails_helper'

# Offline transport contracts: synthetic answers prove routing and privacy, not provider quality or live availability.
RSpec.describe Llm::DecisionChain do
  let(:account) { create(:account) }
  let(:endpoint) { 'https://openrouter.example/api/alpha/decisions' }
  let(:primary_chain) { %w[perplexity/pplx-decider-v1.2 liquid/d1 typesafe/jev-1.14] }
  let(:state) { { 'message' => 'SYNTHETIC_PRIVATE_TRANSPORT_FIXTURE' } }
  let(:questions) do
    { 'route_mode' => { criteria: { 'agent' => 'One agent.', 'human' => 'A staff member.' }, instructions: 'Select a route.' },
      'include_agent_7' => { criteria: { 'yes' => 'Include agent 7.', 'no' => 'Do not include agent 7.' }, instructions: 'Select inclusion.' } }
  end
  let(:answers) { { route_mode: { choice: 'agent', confidence: 0.9 }, include_agent_7: { choice: 'yes', confidence: 0.8 } } }
  let(:locales) { %i[ru kk en] }

  before do
    %w[CAPTAIN_DECISION_MODEL_CHAIN CAPTAIN_AGENT_ROUTING_MODELS CAPTAIN_REPLY_CLAIM_CHECK_MODELS
       CAPTAIN_LANGUAGE_DETECTION_MODEL CAPTAIN_OUTCOME_CLASSIFIER_MODEL CAPTAIN_CUSTOM_GUARDRAIL_MODEL].each do |name|
      InstallationConfig.where(name: name).delete_all
    end
    upsert_installation_config('CAPTAIN_OPENROUTER_API_KEY', 'synthetic-offline-decision-key')
    allow(Llm::Config).to receive(:api_base).and_return('https://openrouter.example/api/v1')
    allow(Llm::OpenRouterModelCatalog).to receive(:model_configs).and_return({})
    allow(Llm::OpenRouterEndpointCatalog).to receive(:endpoint_metadata).and_return({})
  end

  def turn_feature?(feature)
    %i[agent_routing reply_claim_check fact_check_gate inbound_triage].include?(feature)
  end

  def decide(feature, **attributes)
    expect(Internal::FetchOpenRouterGenerationMetadataJob).not_to receive(:perform_later)
    if turn_feature?(feature)
      described_class.decide(feature: feature, account: account, question: { state: state, questions: questions }, **attributes)
    else
      Llm::Runtime.decide(feature: feature, account: account, input: state, options: { decision_questions: questions }, **attributes)
    end
  end

  def success_body(model)
    { id: 'synthetic-native-multi', model: model, provider: 'Synthetic', answers: answers,
      usage: { input_tokens: 10, output_tokens: 2, total_tokens: 12 } }.to_json
  end

  def record_wire(request, seen)
    body = JSON.parse(request.body)
    seen << body.fetch('model')
    expect(body.fetch('state')).to eq(state)
    expect(body.fetch('questions')).to eq(questions.transform_values { |q| q.stringify_keys.merge('type' => 'choice') })
    expect(body.keys).to contain_exactly('model', 'state', 'questions', 'provider')
    expect(body.fetch('provider')).to include('data_collection' => 'deny')
    body
  end

  def record_standard_wire(request, seen)
    record_wire(request, seen).tap do |body|
      if body['model'] == 'respan/span-02'
        expect(body.fetch('provider')).not_to have_key('zdr')
      else
        expect(body.fetch('provider')).to include('zdr' => true)
      end
    end
  end

  %i[agent_routing reply_claim_check fact_check_gate inbound_triage outcome_classification custom_guardrail language_detection].each do |feature|
    (1..3).each do |position|
      it "selects the source defaults for #{feature} and stops after native multi-question answer #{position}" do
        chain = feature == :language_detection ? %w[perplexity/pplx-decider-v1.2 liquid/d1 respan/span-02] : primary_chain
        seen = []
        stub_request(:post, endpoint).to_return do |request|
          body = record_standard_wire(request, seen)
          case seen.size
          when position then { status: 200, body: success_body(body['model']) }
          when 1 then { status: 503, body: 'SYNTHETIC_PRIVATE_PROVIDER_BODY' }
          else { status: 200, body: { model: body['model'], answers: {} }.to_json }
          end
        end
        result = decide(feature)

        expect(seen).to eq(chain.first(position))
        expect(result.model).to eq(chain[position - 1])
        expect(result.answers.transform_values(&:choice)).to eq('route_mode' => 'agent', 'include_agent_7' => 'yes')
        expect(a_request(:post, endpoint)).to have_been_made.times(position)
        events = LlmEvent.where(account_id: account.id, event_name: 'llm.decision.complete').order(:id)
        expect(events.map { |event| event.payload['requested_model'] }).to eq(seen)
        expect(events.last.payload).to include('openrouter_native_endpoint' => '/alpha/decisions', 'decision_chain_position' => position)
        expect(events.map(&:payload).to_json).not_to include('SYNTHETIC_PRIVATE', 'synthetic-offline-decision-key')
      end
    end

    it "terminates #{feature} after exactly three native failures with no extra HTTP" do
      seen = []
      stub_request(:post, endpoint).to_return do |request|
        record_wire(request, seen)
        { status: 503, body: 'SYNTHETIC_PRIVATE_PROVIDER_BODY' }
      end
      error = turn_feature?(feature) ? Llm::DecisionChain::ExhaustedError : Llm::OpenRouterDecisionClient::Error

      expect { decide(feature) }.to raise_error(error)

      expected = feature == :language_detection ? %w[perplexity/pplx-decider-v1.2 liquid/d1 respan/span-02] : primary_chain
      expect(seen).to eq(expected)
      expect(a_request(:post, endpoint)).to have_been_made.times(3)
    end

    it "propagates egress revocation for #{feature} without sending or falling back" do
      expect do
        Llm::EgressGuard.with(validation: -> { raise StandardError, 'synthetic permission revoked' }) { decide(feature) }
      end.to raise_error(Llm::EgressGuard::Blocked, 'LLM egress permission revoked')

      expect(a_request(:any, /.*/)).not_to have_been_made
    end
  end

  it 'keeps new selectable models native-only despite a refreshed chat catalog claiming tools and reasoning' do
    %w[liquid/d1 cloudflare/clef].each do |model|
      allow(Llm::OpenRouterModelCatalog).to receive(:model_configs).and_return(
        model => { 'provider' => 'openrouter', 'type' => 'chat', 'capabilities' => %w[tool_calling reasoning structured_output] }
      )
      expect(Llm::Models.model_config(model)).to include('type' => 'decision', 'capabilities' => %w[decision_classification])
      expect(Llm::Models.model_allowed_for_feature?('agent_routing', model)).to be(true)
      expect(Llm::Models.model_allowed_for_feature?('assistant', model)).to be(false)
      seen = []
      stub_request(:post, endpoint).to_return do |request|
        body = record_wire(request, seen)
        { status: 200, body: success_body(body['model']) }
      end

      question = { state: state, questions: questions }
      result = described_class.decide(feature: :agent_routing, account: account, models: [model], question: question)
      expect(result.model).to eq(model)
      expect(seen).to eq([model])
    end
  end

  it 'keeps the ZDR provider filter on every fallback when privacy requires it, including a non-ZDR model' do
    seen = []
    stub_request(:post, endpoint).to_return do |request|
      body = record_wire(request, seen)
      expect(body.fetch('provider')).to include('zdr' => true, 'allow_fallbacks' => false)
      { status: 503, body: 'Synthetic unavailable ZDR endpoint.' }
    end

    expect { decide(:language_detection, privacy_profile: 'zdr_required') }.to raise_error(Llm::OpenRouterDecisionClient::Error)
    expect(seen).to eq(%w[perplexity/pplx-decider-v1.2 liquid/d1 respan/span-02])
  end

  it 'does not offer a model without endpoint ZDR evidence under mandatory ZDR' do
    %w[liquid/d1 cloudflare/clef respan/span-02].each do |model|
      result = Llm::OpenRouterCapabilityResolver.call(model_id: model, feature: 'agent_routing',
                                                      runtime_preferences: { privacy_profile: 'zdr_required' })
      expect(result).not_to be_allowed
      expect(result.reasons.map { |reason| reason[:code] }).to include('zdr_required_unsupported')
    end
    expect(a_request(:any, /.*/)).not_to have_been_made
  end

  it 'keeps installation defaults, runtime defaults and all three UI hint locales in agreement' do
    installation = YAML.load_file(Rails.root.join('config/installation_config.yml')).index_by { |entry| entry['name'] }
    %w[CAPTAIN_DECISION_MODEL_CHAIN CAPTAIN_AGENT_ROUTING_MODELS CAPTAIN_REPLY_CLAIM_CHECK_MODELS].each do |key|
      expect(JSON.parse(installation.fetch(key).fetch('value'))).to eq(primary_chain)
    end
    %w[CAPTAIN_LANGUAGE_DETECTION_MODEL CAPTAIN_OUTCOME_CLASSIFIER_MODEL CAPTAIN_CUSTOM_GUARDRAIL_MODEL].each do |key|
      expect(installation.fetch(key).fetch('value')).to eq(primary_chain.first)
      locales.each do |locale|
        hint = I18n.t("super_admin.app_config.fields.#{key}.hint", locale: locale, fallback: false, raise: true)
        last = key == 'CAPTAIN_LANGUAGE_DETECTION_MODEL' ? 'Respan Span 02' : 'TypeSafe JEV'
        expect(hint).to include("Perplexity Decider → Liquid D1 → #{last}")
      end
    end
  end
end
