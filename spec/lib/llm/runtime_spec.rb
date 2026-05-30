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
