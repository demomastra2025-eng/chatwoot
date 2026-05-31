# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::Runtime do
  let(:account) { instance_double(Account, id: 42) }

  it 'dispatches chat feature requests to the OpenRouter runtime' do
    request = Llm::FeatureRequest.new(
      feature: :captain_agent,
      account: account,
      messages: [{ role: 'user', content: 'Hello' }]
    )
    openrouter_runtime = instance_double(Llm::OpenRouterRuntime, chat: :response)

    expect(Llm::OpenRouterRuntime).to receive(:new).with(account: account).and_return(openrouter_runtime)

    expect(described_class.chat(request)).to eq(:response)
  end

  it 'dispatches stateful chat construction through the OpenRouter runtime facade' do
    request = Llm::FeatureRequest.new(
      feature: :captain_agent,
      account: account,
      model: 'openai/gpt-5.4-mini'
    )
    openrouter_runtime = instance_double(Llm::OpenRouterRuntime, build_chat: :chat)

    expect(Llm::OpenRouterRuntime).to receive(:new).with(account: account).and_return(openrouter_runtime)

    expect(described_class.build_chat(request)).to eq(:chat)
  end

  it 'preserves accountless installation-scoped moderation requests in the runtime facade' do
    openrouter_runtime = instance_double(Llm::OpenRouterRuntime, build_chat: :chat)

    expect(Llm::OpenRouterRuntime).to receive(:new).with(account: nil).and_return(openrouter_runtime)
    expect(openrouter_runtime).to receive(:build_chat) do |request|
      expect(request).to be_a(Llm::FeatureRequest)
      expect(request.feature_key).to eq('moderation')
      expect(request.account).to be_nil
      :chat
    end

    expect(described_class.build_chat(feature: :moderation, account: nil, model: 'openai/gpt-oss-safeguard-20b')).to eq(:chat)
  end

  it 'preserves feature requests from string-keyed hashes in the runtime facade' do
    openrouter_runtime = instance_double(Llm::OpenRouterRuntime, build_chat: :chat)

    expect(Llm::OpenRouterRuntime).to receive(:new).with(account: nil).and_return(openrouter_runtime)
    expect(openrouter_runtime).to receive(:build_chat) do |request|
      expect(request.feature_key).to eq('moderation')
      :chat
    end

    expect(described_class.build_chat({ 'feature' => 'moderation', 'model' => 'openai/gpt-oss-safeguard-20b' })).to eq(:chat)
  end

  it 'dispatches stateful chat asks through the OpenRouter runtime facade' do
    chat = instance_double(RubyLLM::Chat)
    openrouter_runtime = instance_double(Llm::OpenRouterRuntime, ask: :response)

    expect(Llm::OpenRouterRuntime).to receive(:new).with(account: account).and_return(openrouter_runtime)
    expect(openrouter_runtime)
      .to receive(:ask)
      .with(chat, 'hello', model: 'openai/gpt-5.4-mini', observability: {})
      .and_return(:response)

    expect(described_class.ask(chat, 'hello', account: account, model: 'openai/gpt-5.4-mini', observability: {})).to eq(:response)
  end

  it 'builds feature requests from keyword arguments' do
    openrouter_runtime = instance_double(Llm::OpenRouterRuntime, embed: :embedding)

    expect(Llm::OpenRouterRuntime).to receive(:new).with(account: account).and_return(openrouter_runtime)
    expect(openrouter_runtime).to receive(:embed) do |request|
      expect(request).to be_a(Llm::FeatureRequest)
      expect(request.feature_key).to eq('embedding')
      expect(request.input).to eq('hello')
      :embedding
    end

    result = described_class.embed(feature: :help_center_search, account: account, input: 'hello')

    expect(result).to eq(:embedding)
  end

  it 'dispatches rerank feature requests to the OpenRouter runtime' do
    openrouter_runtime = instance_double(Llm::OpenRouterRuntime, rerank: :reranked)

    expect(Llm::OpenRouterRuntime).to receive(:new).with(account: account).and_return(openrouter_runtime)
    expect(openrouter_runtime).to receive(:rerank) do |request|
      expect(request.feature_key).to eq('knowledge_rerank')
      expect(request.input).to eq(query: 'refund', documents: ['refund policy'])
      :reranked
    end

    expect(
      described_class.rerank(account: account, input: { query: 'refund', documents: ['refund policy'] })
    ).to eq(:reranked)
  end

  it 'dispatches metadata lookups to the requested provider runtime' do
    openrouter_runtime = instance_double(Llm::OpenRouterRuntime, metadata: :metadata)

    expect(Llm::OpenRouterRuntime).to receive(:new).with(account: nil).and_return(openrouter_runtime)
    expect(openrouter_runtime).to receive(:metadata).with('gen_123').and_return(:metadata)

    expect(described_class.metadata(provider: :openrouter, generation_id: 'gen_123')).to eq(:metadata)
  end

  it 'rejects unsupported runtime providers' do
    expect { described_class.metadata(provider: :openai, generation_id: 'gen_123') }
      .to raise_error(ArgumentError, /Unsupported LLM runtime provider/)
  end
end
