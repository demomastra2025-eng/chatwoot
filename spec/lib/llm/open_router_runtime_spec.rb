# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::OpenRouterRuntime do
  let(:account) { instance_double(Account, id: 42) }
  let(:runtime) { described_class.new(account: account) }

  before do
    allow(Llm::Config).to receive(:api_key).with('openrouter', account: account).and_return('openrouter-key')
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
        observability: hash_including(trace_id: 'trace-1', provider: 'openrouter', feature: 'captain_agent')
      )
    ).and_return(runner)

    expect(runtime.chat(request)).to eq(:response)
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

    expect(Llm::ChatClient).to receive(:ask).with(
      chat,
      'hello',
      model: 'openai/gpt-5.4-mini',
      account: account,
      observability: { trace_id: 'trace-1' }
    ).and_return(response)

    expect(runtime.ask(chat, 'hello', model: 'openai/gpt-5.4-mini', observability: { trace_id: 'trace-1' })).to eq(response)
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

    expect(runtime.embed(request)).to eq(result)
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
      'dimensions' => 2
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

    expect(runtime.transcribe(request)).to eq(result)
  end

  it 'routes native rerank requests to the OpenRouter rerank client' do
    request = Llm::FeatureRequest.new(
      feature: :knowledge_rerank,
      account: account,
      model: 'cohere/rerank-v3.5',
      input: { query: 'refund policy', documents: ['refunds are available', 'shipping policy'] },
      options: { top_n: 1 }
    )
    result = instance_double(Llm::OpenRouterRerankClient::Result)

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

    expect(runtime.rerank(request)).to eq(result)
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
