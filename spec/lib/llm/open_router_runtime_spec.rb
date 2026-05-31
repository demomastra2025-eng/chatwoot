# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::OpenRouterRuntime do
  let(:account) { instance_double(Account, id: 42) }
  let(:runtime) { described_class.new(account: account) }

  before do
    allow(Llm::Config).to receive(:api_key).and_call_original
    allow(Llm::Config).to receive(:api_key).with('openrouter', account: account).and_return('openrouter-key')
    allow(Llm::Config).to receive(:api_base).and_call_original
    allow(Llm::Config).to receive(:api_base).with('openrouter', account: account).and_return('https://openrouter.example/api/v1')
  end

  it 'runs chat requests through ChatRequestRunner with feature observability preserved' do
    schema = Class.new(RubyLLM::Schema) do
      string :message
    end
    tool = instance_double(RubyLLM::Tool, name: 'lookup_contact')
    context = instance_double(RubyLLM::Context)
    request = Llm::FeatureRequest.new(
      feature: :captain_agent,
      account: account,
      model: 'openai/gpt-5.4-mini',
      messages: [{ role: 'user', content: 'Hello' }],
      schema: schema,
      tools: [tool],
      observability: { trace_id: 'trace-1' },
      options: { context: context, temperature: 0.2 }
    )
    runner = instance_double(Llm::ChatRequestRunner, call: :response)

    expect(Llm::ChatRequestRunner).to receive(:new).with(
      hash_including(
        context: context,
        model: 'openai/gpt-5.4-mini',
        messages: [{ role: 'user', content: 'Hello' }],
        schema: schema,
        tools: [tool],
        account: account,
        feature: 'captain_agent',
        temperature: 0.2,
        observability: hash_including(
          trace_id: 'trace-1',
          provider: 'openrouter',
          feature: 'captain_agent',
          requested_model: 'openai/gpt-5.4-mini',
          routing_profile: 'balanced',
          openrouter_allow_fallbacks: true,
          openrouter_require_parameters: true,
          openrouter_plugins: ['response-healing'],
          openrouter_cache_policy: 'session'
        )
      )
    ).and_return(runner)

    expect(runtime.chat(request)).to eq(:response)
  end

  it 'blocks chat provider execution when the local account budget is exhausted' do
    persisted_account = create(:account)
    budgeted_runtime = described_class.new(account: persisted_account)
    request = Llm::FeatureRequest.new(
      feature: :captain_agent,
      account: persisted_account,
      model: 'openai/gpt-5.4-mini',
      messages: [{ role: 'user', content: 'Hello' }]
    )
    create(:llm_budget_policy, account: persisted_account, daily_budget: 1.0, hard_stop: true)
    create(:llm_usage_event, account: persisted_account, estimated_cost: 1.01, occurred_at: Time.zone.now)

    expect(Llm::ChatRequestRunner).not_to receive(:new)

    expect { budgeted_runtime.chat(request) }
      .to raise_error(Llm::BudgetEvaluator::BudgetExceededError, /daily_budget_exceeded/)
  end

  it 'builds stateful chats through the compiled OpenRouter runtime profile' do
    context = instance_double(RubyLLM::Context)
    chat = instance_double(RubyLLM::Chat)
    request = Llm::FeatureRequest.new(
      feature: :captain_agent,
      account: account,
      model: 'openai/gpt-5.4-mini',
      options: {
        context: context,
        temperature: 0.2,
        params: { provider: { sort: 'price' }, top_p: 0.9 }
      }
    )

    expect(Llm::ChatClient).to receive(:build).with(
      hash_including(
        context: context,
        model: 'openai/gpt-5.4-mini',
        account: account,
        feature: 'captain_agent',
        temperature: 0.2,
        observability: hash_including(
          provider: 'openrouter',
          requested_model: 'openai/gpt-5.4-mini',
          routing_profile: 'balanced',
          openrouter_require_parameters: true
        ),
        routing_metadata: hash_including(
          requested_model: 'openai/gpt-5.4-mini',
          routing_profile: 'balanced',
          openrouter_require_parameters: true
        ),
        params: hash_including(
          top_p: 0.9,
          models: start_with('openai/gpt-5.4-mini'),
          provider: include(require_parameters: true, allow_fallbacks: true, data_collection: 'deny')
        )
      )
    ).and_return(chat)

    expect(runtime.build_chat(request)).to eq(chat)
  end

  it 'asks stateful chats through the runtime facade' do
    chat = instance_double(RubyLLM::Chat)
    response = instance_double(RubyLLM::Message)
    Llm::OpenRouterRequestPolicy.tag!(
      chat,
      feature: :captain_agent,
      account: account,
      model: 'openai/gpt-5.4-mini',
      routing_metadata: {
        requested_model: 'openai/gpt-5.4-mini',
        routing_profile: 'balanced',
        openrouter_provider_order: ['OpenAI'],
        openrouter_require_parameters: true
      }
    )

    expect(Llm::ChatClient).to receive(:ask).with(
      chat,
      'hello',
      model: 'openai/gpt-5.4-mini',
      account: account,
      observability: hash_including(
        trace_id: 'trace-1',
        provider: 'openrouter',
        feature: 'captain_agent',
        requested_model: 'openai/gpt-5.4-mini',
        routing_profile: 'balanced',
        openrouter_provider_order: ['OpenAI'],
        openrouter_require_parameters: true
      )
    ).and_return(response)

    expect(runtime.ask(chat, 'hello', model: 'openai/gpt-5.4-mini', observability: { trace_id: 'trace-1' })).to eq(response)
  end

  it 'blocks budget-exceeded chat requests before provider execution' do
    budget_account = create(:account)
    budget_runtime = described_class.new(account: budget_account)
    create(:llm_budget_policy, account: budget_account, daily_budget: 0, hard_stop: true)
    request = Llm::FeatureRequest.new(
      feature: :captain_agent,
      account: budget_account,
      model: 'openai/gpt-5.4-mini',
      messages: [{ role: 'user', content: 'Hello' }],
      options: { estimated_cost: 0.01 }
    )

    expect(Llm::ChatRequestRunner).not_to receive(:new)

    expect { budget_runtime.chat(request) }
      .to raise_error(Llm::BudgetEvaluator::BudgetExceededError, /daily_budget_exceeded/)
  end

  it 'blocks observed stateful asks when the account budget is exhausted' do
    budget_account = create(:account)
    budget_runtime = described_class.new(account: budget_account)
    create(:llm_budget_policy, account: budget_account, daily_budget: 0, hard_stop: true)
    chat = instance_double(RubyLLM::Chat)

    expect(Llm::ChatClient).not_to receive(:ask)

    expect do
      budget_runtime.ask(
        chat,
        'hello',
        model: 'openai/gpt-5.4-mini',
        observability: { feature: 'assistant', estimated_cost: 0.01 }
      )
    end.to raise_error(Llm::BudgetEvaluator::BudgetExceededError, /daily_budget_exceeded/)
  end

  it 'blocks stateful asks without feature observability when the account budget is exhausted' do
    budget_account = create(:account)
    budget_runtime = described_class.new(account: budget_account)
    create(:llm_budget_policy, account: budget_account, daily_budget: 0, hard_stop: true)
    chat = instance_double(RubyLLM::Chat)

    expect(Llm::ChatClient).not_to receive(:ask)

    expect do
      budget_runtime.ask(chat, 'hello', model: 'openai/gpt-5.4-mini', observability: { trace_id: 'trace-1' })
    end.to raise_error(Llm::BudgetEvaluator::BudgetExceededError, /daily_budget_exceeded/)
  end

  it 'routes native embeddings to the OpenRouter embedding client' do
    request = Llm::FeatureRequest.new(
      feature: :help_center_search,
      account: account,
      model: 'openai/text-embedding-3-small',
      input: ['hello'],
      options: { dimensions: 1536, input_type: 'search_query' }
    )
    result = instance_double(Llm::OpenRouterEmbeddingClient::Result, vectors: [[0.1]], input_tokens: 1, model: 'openai/text-embedding-3-small')

    expect(Llm::OpenRouterEmbeddingClient).to receive(:embed).with(
      ['hello'],
      hash_including(
        model: 'openai/text-embedding-3-small',
        dimensions: 1536,
        input_type: 'search_query',
        api_key: 'openrouter-key',
        api_base: 'https://openrouter.example/api/v1',
        provider: include(allow_fallbacks: true, data_collection: 'deny')
      )
    ).and_return(result)

    expect { expect(runtime.embed(request)).to eq(result) }
      .to change(LlmUsageEvent, :count).by(1)
    expect(LlmUsageEvent.last).to have_attributes(
      event_name: 'llm.embedding.complete',
      feature: 'help_center_search',
      provider: 'openrouter',
      requested_model: 'openai/text-embedding-3-small',
      routing_profile: 'balanced',
      prompt_tokens: 1,
      total_tokens: 1
    )
    expect(LlmEvent.last.payload).to include(
      'openrouter_native_endpoint' => '/embeddings',
      'openrouter_cache_policy' => 'static_context',
      'requested_model' => 'openai/text-embedding-3-small'
    )
  end

  it 'publishes native embedding observability through the runtime facade' do
    events = []
    subscriber = ActiveSupport::Notifications.subscribe('llm.embedding.complete') do |*args|
      events << ActiveSupport::Notifications::Event.new(*args)
    end
    request = Llm::FeatureRequest.new(
      feature: :help_center_search,
      account: account,
      model: 'openai/text-embedding-3-small',
      input: ['hello'],
      observability: { feature: 'embedding', account_id: 42 },
      options: { dimensions: 1536 }
    )
    result = instance_double(Llm::OpenRouterEmbeddingClient::Result, vectors: [[0.1, 0.2]], input_tokens: 3, model: 'openai/text-embedding-3-small')

    allow(Llm::OpenRouterEmbeddingClient).to receive(:embed).and_return(result)

    expect(runtime.embed(request)).to eq(result)
    expect(events.size).to eq(1)
    expect(events.first.payload).to include(
      'feature' => 'embedding',
      'provider' => 'openrouter',
      'runtime_mode' => 'openrouter_runtime',
      'status' => 'success',
      'vector_count' => 1,
      'dimensions' => 2,
      'requested_model' => 'openai/text-embedding-3-small',
      'openrouter_native_endpoint' => '/embeddings',
      'openrouter_cache_policy' => 'static_context'
    )
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  it 'applies request-scoped ZDR policy to native embeddings' do
    request = Llm::FeatureRequest.new(
      feature: :help_center_search,
      account: account,
      model: 'openai/text-embedding-3-small',
      input: ['hello'],
      runtime_preferences: { privacy_profile: 'zdr_required' },
      options: { dimensions: 1536 }
    )
    result = instance_double(Llm::OpenRouterEmbeddingClient::Result, vectors: [[0.1]], input_tokens: 1, model: 'openai/text-embedding-3-small')

    expect(Llm::OpenRouterEmbeddingClient).to receive(:embed).with(
      ['hello'],
      hash_including(
        provider: include(
          allow_fallbacks: false,
          data_collection: 'deny',
          zdr: true
        )
      )
    ).and_return(result)

    expect(runtime.embed(request)).to eq(result)
  end

  it 'routes native transcription to the OpenRouter transcription client' do
    request = Llm::FeatureRequest.new(
      feature: :audio_transcription,
      account: account,
      model: 'openai/gpt-4o-mini-transcribe',
      input: '/tmp/audio.ogg',
      options: { language: 'ru', temperature: 0.1 }
    )
    result = instance_double(RubyLLM::Transcription, text: 'Привет')

    expect(Llm::OpenRouterTranscriptionClient).to receive(:transcribe).with(
      '/tmp/audio.ogg',
      hash_including(
        model: 'openai/gpt-4o-mini-transcribe',
        language: 'ru',
        temperature: 0.1,
        api_key: 'openrouter-key',
        api_base: 'https://openrouter.example/api/v1',
        provider: include(allow_fallbacks: true, data_collection: 'deny')
      )
    ).and_return(result)

    expect { expect(runtime.transcribe(request)).to eq(result) }
      .to change(LlmUsageEvent, :count).by(1)
    expect(LlmUsageEvent.last).to have_attributes(
      event_name: 'llm.transcription.complete',
      feature: 'audio_transcription',
      provider: 'openrouter'
    )
  end

  it 'retries transient native OpenRouter provider errors once and records a retry event' do
    request = Llm::FeatureRequest.new(
      feature: :audio_transcription,
      account: account,
      model: 'openai/gpt-4o-mini-transcribe',
      input: '/tmp/audio.ogg'
    )
    result = instance_double(RubyLLM::Transcription, text: 'Привет')
    retry_events = []
    call_count = 0
    subscriber = ActiveSupport::Notifications.subscribe('llm.run.retry') do |*args|
      retry_events << ActiveSupport::Notifications::Event.new(*args)
    end

    expect(Llm::OpenRouterTranscriptionClient).to receive(:transcribe).twice do
      call_count += 1
      raise RubyLLM::Error, 'OpenRouter provider error: 503 upstream unavailable Bearer sk-or-v1-secret' if call_count == 1

      result
    end

    expect(runtime.transcribe(request)).to eq(result)
    expect(retry_events.size).to eq(1)
    expect(retry_events.first.payload).to include(
      'feature' => 'audio_transcription',
      'provider' => 'openrouter',
      'reason' => 'provider_error',
      'openrouter_error_category' => 'provider_error',
      'attempt' => 1,
      'max_attempts' => 2,
      'error_message' => 'OpenRouter provider error: 503 upstream unavailable Bearer [REDACTED]'
    )
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  it 'routes native rerank requests to the OpenRouter rerank client' do
    request = Llm::FeatureRequest.new(
      feature: :knowledge_rerank,
      account: account,
      model: 'cohere/rerank-v3.5',
      input: { query: 'refund policy', documents: ['refunds are available', 'shipping policy'] },
      options: { top_n: 1 }
    )
    result = Llm::OpenRouterRerankClient::Result.new(
      results: [Llm::OpenRouterRerankClient::ResultItem.new(index: 0, relevance_score: 0.9)],
      model: 'cohere/rerank-v3.5',
      usage: { 'total_tokens' => 12, 'cost' => '0.00003' }
    )

    expect(Llm::OpenRouterRerankClient).to receive(:rerank).with(
      hash_including(
        query: 'refund policy',
        documents: ['refunds are available', 'shipping policy'],
        model: 'cohere/rerank-v3.5',
        top_n: 1,
        return_documents: true,
        api_key: 'openrouter-key',
        api_base: 'https://openrouter.example/api/v1',
        provider: include(allow_fallbacks: true, data_collection: 'deny')
      )
    ).and_return(result)

    expect { expect(runtime.rerank(request)).to eq(result) }
      .to change(LlmUsageEvent, :count).by(1)
    expect(LlmUsageEvent.last).to have_attributes(
      event_name: 'llm.rerank.complete',
      feature: 'knowledge_rerank',
      provider: 'openrouter',
      total_tokens: 12
    )
    expect(LlmUsageEvent.last.estimated_cost.to_f).to eq(0.00003)
  end

  it 'delegates generation metadata lookup to the OpenRouter generation client' do
    result = instance_double(Llm::OpenRouterGenerationClient::Result)

    expect(Llm::OpenRouterGenerationClient).to receive(:fetch).with(
      'gen_123',
      api_key: 'openrouter-key',
      api_base: 'https://openrouter.example/api/v1'
    ).and_return(result)

    expect(runtime.metadata('gen_123')).to eq(result)
  end

  it 'uses product model config keys for availability and diagnostics' do
    diagnostic = instance_double(Llm::OpenRouterCapabilityResolver::Result)

    expect(Llm::Models).to receive(:models_for)
      .with('assistant', account: account, runtime_filtered: true)
      .and_return(['openai/gpt-5.4-mini'])
    expect(runtime.available_models(:captain_agent)).to eq(['openai/gpt-5.4-mini'])

    expect(Llm::OpenRouterCapabilityResolver).to receive(:call).with(
      model_id: 'openai/gpt-5.4-mini',
      feature: 'assistant',
      account: account,
      runtime_preferences: nil,
      runtime_filtered: true
    ).and_return(diagnostic)
    expect(runtime.diagnose_model('openai/gpt-5.4-mini', :captain_agent)).to eq(diagnostic)
  end
end
