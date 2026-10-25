# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::DecisionChain do
  let(:account) { create(:account) }
  let(:api_key) { 'synthetic-decision-chain-key' }
  let(:endpoint) { 'https://openrouter.example/api/alpha/decisions' }
  let(:criteria) do
    { 'agent_ent' => 'SYNTHETIC_PRIVATE_CRITERION: the ENT doctors agent books the doctor.',
      'agent_procedures' => 'The ENT procedures agent.', 'human' => 'A staff member.' }
  end
  let(:question) do
    { state: { 'message' => 'SYNTHETIC_PRIVATE_PATIENT_TEXT' }, criteria: criteria,
      instructions: 'SYNTHETIC_PRIVATE_INSTRUCTIONS: choose who answers.' }
  end

  before do
    allow(Llm::Config).to receive(:api_key).and_call_original
    allow(Llm::Config).to receive(:api_key).with('openrouter', account: account).and_return(api_key)
    allow(Llm::Config).to receive(:api_base).and_call_original
    allow(Llm::Config).to receive(:api_base).with('openrouter', account: account).and_return('https://openrouter.example/api/v1')
  end

  def answer(model, choice: 'agent_ent', confidence: 0.92)
    { status: 200, body: { id: "gen-#{model.tr('/', '-')}", model: model, provider: 'Synthetic',
                           answers: { reason: { choice: choice, confidence: confidence,
                                                probabilities: { agent_ent: confidence, agent_procedures: 0.05, human: 0.03 } } },
                           usage: { input_tokens: 80, output_tokens: 1, total_tokens: 81 } }.to_json }
  end

  def stub_decision_model(model, response)
    stub_request(:post, endpoint).with { |request| JSON.parse(request.body)['model'] == model }.to_return(response)
  end

  # The shared chain of the turn decision features; agent_routing has a chain of its own (see '.models').
  def decide(**)
    described_class.decide(feature: :fact_check_gate, account: account, question: question, **)
  end

  def chain_events
    LlmEvent.where(account_id: account.id, event_name: 'llm.decision.complete').order(:id)
  end

  it 'answers with the head of the chain in one call and returns the choice, confidence, probabilities and model' do
    head = stub_decision_model('inception/mercury-decide', answer('inception/mercury-decide'))

    result = decide(observability: { trace_id: 'synthetic-trace' })

    expect(result).to have_attributes(choice: 'agent_ent', confidence: 0.92, model: 'inception/mercury-decide',
                                      served_model: 'inception/mercury-decide', position: 1)
    expect(result.probabilities).to eq('agent_ent' => 0.92, 'agent_procedures' => 0.05, 'human' => 0.03)
    expect(result).not_to be_fallback
    expect(head).to have_been_requested.once
    expect(chain_events.map { |event| [event.feature, event.status, event.payload['decision_chain_position']] })
      .to eq([['fact_check_gate', 'success', 1]])
  end

  it 'gives every model its short timeout of the profile' do
    stub_decision_model('inception/mercury-decide', answer('inception/mercury-decide'))
    expect(Llm::OpenRouterDecisionClient).to receive(:choose).with(hash_including(model: 'inception/mercury-decide', timeout: 2.0))
                                                             .and_call_original

    decide
  end

  it 'passes the same question to the next model when one fails or times out and records which model answered' do
    first = stub_decision_model('inception/mercury-decide', { status: 503, body: { error: { message: "#{api_key} provider text" } }.to_json })
    second = stub_request(:post, endpoint).with { |request| JSON.parse(request.body)['model'] == 'microsoft/microsoft-decision-1' }
                                          .to_timeout
    third = stub_decision_model('openai/gpt-6-luna-decisions', answer('openai/gpt-6-luna-decisions', choice: 'human', confidence: 0.81))

    result = decide

    expect(result).to have_attributes(choice: 'human', confidence: 0.81, model: 'openai/gpt-6-luna-decisions', position: 3)
    expect(result).to be_fallback
    expect([first, second, third]).to all(have_been_requested.once)
    expect(a_request(:post, endpoint).with do |request|
      body = JSON.parse(request.body)
      body['state'] == question[:state] && body.dig('questions', 'reason', 'criteria') == criteria
    end).to have_been_made.times(3)
    expect(chain_events.map { |event| [event.payload['requested_model'], event.status, event.payload['decision_chain_position']] })
      .to eq([['inception/mercury-decide', 'error', 1], ['microsoft/microsoft-decision-1', 'error', 2],
              ['openai/gpt-6-luna-decisions', 'success', 3]])
    expect(chain_events.map(&:payload).to_json).not_to include('SYNTHETIC_PRIVATE', api_key)
  end

  it 'raises one well-defined error naming the models tried when no model answers' do
    stub_request(:post, endpoint).to_return(status: 500, body: "#{api_key} SYNTHETIC_PRIVATE_PROVIDER_TEXT")

    expect { decide }.to raise_error(described_class::ExhaustedError) do |error|
      expect(error.feature).to eq('fact_check_gate')
      expect(error.attempts).to eq(described_class::DEFAULT_MODELS.map do |model|
        { model: model, error_class: 'Llm::OpenRouterDecisionClient::Error' }
      end)
      expect(error.message).to start_with('No decision model answered for fact_check_gate')
      expect(error.message).not_to include(api_key, 'SYNTHETIC_PRIVATE')
    end
    expect(a_request(:post, endpoint)).to have_been_made.times(3)
  end

  it 'treats an answer outside the criteria as a failure of that model' do
    stub_decision_model('inception/mercury-decide', answer('inception/mercury-decide', choice: 'agent_invented'))
    stub_decision_model('microsoft/microsoft-decision-1', answer('microsoft/microsoft-decision-1'))

    expect(decide).to have_attributes(choice: 'agent_ent', model: 'microsoft/microsoft-decision-1', position: 2)
  end

  it 'stops within the total bound instead of starting a call that cannot finish' do
    expect { decide(total_timeout: 0.1) }.to raise_error(described_class::ExhaustedError) do |error|
      expect(error.attempts).to eq([])
    end
    expect(a_request(:post, endpoint)).not_to have_been_made

    expect(Llm::OpenRouterDecisionClient).to receive(:choose) do |**options|
      expect(options[:timeout]).to be <= 1.0
      Llm::OpenRouterDecisionClient::Result.new(choice: 'agent_ent', confidence: 0.9, probabilities: {}, model: 'inception/mercury-decide')
    end
    expect(decide(total_timeout: 1.0).position).to eq(1)
  end

  it 'refuses a feature that is not a decision feature before any call' do
    expect { described_class.decide(feature: :captain_agent, account: account, question: question) }
      .to raise_error(ArgumentError, 'Decisions is unavailable for this feature.')
    expect(a_request(:post, endpoint)).not_to have_been_made
  end

  describe 'several questions in one call' do
    let(:questions) do
      { 'route_mode' => { criteria: { 'route_agent' => 'One agent.', 'council' => 'Several agents.' }, instructions: 'Route.' },
        'include_agent_84' => { criteria: { 'yes' => 'Agent 84 handles it.', 'no' => 'It does not.' }, instructions: 'Include?' } }
    end

    it 'sends every question in one call and returns the answer of each question' do
      stub = stub_request(:post, endpoint).with do |request|
        body = JSON.parse(request.body)
        body['model'] == 'perplexity/pplx-decider-v1.2' && body['questions'].keys == %w[route_mode include_agent_84] &&
          body.dig('questions', 'include_agent_84', 'criteria') == questions['include_agent_84'][:criteria].stringify_keys
      end.to_return(status: 200, body: { id: 'gen-1', model: 'perplexity/pplx-decider-v1.2',
                                         answers: { route_mode: { choice: 'route_agent', confidence: 0.97 },
                                                    include_agent_84: { choice: 'yes', confidence: 0.91 } } }.to_json)

      result = described_class.decide(feature: :agent_routing, account: account, question: { state: { 'm' => 'x' }, questions: questions })

      expect(stub).to have_been_requested.once
      expect(result.answers.transform_values(&:choice)).to eq('route_mode' => 'route_agent', 'include_agent_84' => 'yes')
      expect(result).to have_attributes(confidence: 0.91, model: 'perplexity/pplx-decider-v1.2', position: 1)
      expect(chain_events.last.payload['decision_choice']).to eq('route_mode=route_agent include_agent_84=yes')
    end

    it 'asks only the models the caller names (the evaluation harness)' do
      stub = stub_decision_model('typesafe/jev-1.14', answer('typesafe/jev-1.14'))

      expect(decide(models: ['typesafe/jev-1.14', 'vendor/unknown'])).to have_attributes(model: 'typesafe/jev-1.14', position: 1)
      expect(stub).to have_been_requested.once
    end
  end

  describe '.models' do
    it 'is the built-in chain while the platform setting is absent, blank or unreadable' do
      InstallationConfig.where(name: described_class::CONFIG_NAME).delete_all
      expect(described_class.models).to eq(%w[inception/mercury-decide microsoft/microsoft-decision-1 openai/gpt-6-luna-decisions])

      ['', '[not json', '["openai/gpt-6-luna", "vendor/unknown-decision"]'].each do |value|
        upsert_installation_config(described_class::CONFIG_NAME, value)
        expect(described_class.models).to eq(described_class::DEFAULT_MODELS)
      end
    end

    it 'follows the platform setting, keeping only supported decision models, at most three' do
      upsert_installation_config(described_class::CONFIG_NAME,
                                 '["microsoft/microsoft-decision-1", "openai/gpt-6-luna", "inception/mercury-decide", ' \
                                 '"microsoft/microsoft-decision-1", "openai/gpt-6-luna-decisions", "microsoft/microsoft-decision-1-20261009"]')
      expect(described_class.models).to eq(%w[microsoft/microsoft-decision-1 inception/mercury-decide openai/gpt-6-luna-decisions])

      upsert_installation_config(described_class::CONFIG_NAME, 'openai/gpt-6-luna-decisions, inception/mercury-decide')
      expect(described_class.models).to eq(%w[openai/gpt-6-luna-decisions inception/mercury-decide])
    end

    it 'gives agent_routing its own chain: Perplexity Decider, then JEV, then Mercury Decide, and never the shared one' do
      InstallationConfig.where(name: 'CAPTAIN_AGENT_ROUTING_MODELS').delete_all
      upsert_installation_config(described_class::CONFIG_NAME, '["openai/gpt-6-luna-decisions"]')

      expect(described_class.models(:agent_routing)).to eq(%w[perplexity/pplx-decider-v1.2 typesafe/jev-1.14 inception/mercury-decide])
      expect(described_class.models(:agent_routing)).not_to include('openai/gpt-6-luna-decisions')

      upsert_installation_config('CAPTAIN_AGENT_ROUTING_MODELS', '["typesafe/jev-1.14", "perplexity/pplx-decider-flash-v1.2"]')
      expect(described_class.models(:agent_routing)).to eq(%w[typesafe/jev-1.14 perplexity/pplx-decider-flash-v1.2])
      expect(described_class.models(:fact_check_gate)).to eq(%w[openai/gpt-6-luna-decisions])
    end

    it 'asks the models in the order of the platform setting' do
      upsert_installation_config(described_class::CONFIG_NAME, '["microsoft/microsoft-decision-1", "inception/mercury-decide"]')
      first = stub_decision_model('microsoft/microsoft-decision-1', answer('microsoft/microsoft-decision-1'))

      expect(decide).to have_attributes(model: 'microsoft/microsoft-decision-1', position: 1)
      expect(first).to have_been_requested.once
      expect(a_request(:post, endpoint).with { |request| JSON.parse(request.body)['model'] == 'inception/mercury-decide' })
        .not_to have_been_made
    end
  end
end
