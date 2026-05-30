# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::OpenRouterEmbeddingClient do
  let(:dimensions) { Captain::KnowledgeSettings::VECTOR_DIMENSIONS }
  let(:vector) { Array.new(dimensions, 0.1) }
  let(:second_vector) { Array.new(dimensions, 0.2) }

  it 'posts a single embedding request to the native OpenRouter embeddings endpoint' do
    stub = stub_request(:post, 'https://openrouter.ai/api/v1/embeddings')
           .with(headers: { 'Authorization' => 'Bearer openrouter-key', 'Accept' => 'application/json' }) do |request|
      body = JSON.parse(request.body)
      expect(body).to include(
        'model' => 'openai/text-embedding-3-small',
        'input' => 'hello',
        'dimensions' => dimensions
      )
    end.to_return(
      status: 200,
      body: {
        model: 'openai/text-embedding-3-small',
        usage: { input_tokens: 5 },
        data: [{ index: 0, embedding: vector }]
      }.to_json,
      headers: { 'Content-Type' => 'application/json' }
    )

    result = described_class.embed(
      'hello',
      model: 'openai/text-embedding-3-small',
      dimensions: dimensions,
      api_key: 'openrouter-key',
      api_base: 'https://openrouter.ai/api/v1'
    )

    expect(stub).to have_been_requested
    expect(result.vectors).to eq([vector])
    expect(result.input_tokens).to eq(5)
    expect(result.model).to eq('openai/text-embedding-3-small')
  end

  it 'supports batch input and preserves response index ordering' do
    stub = stub_request(:post, 'https://openrouter.ai/api/v1/embeddings')
           .with(headers: { 'Authorization' => 'Bearer openrouter-key' }) do |request|
      body = JSON.parse(request.body)
      expect(body).to include(
        'model' => 'baai/bge-m3',
        'input' => %w[first second],
        'dimensions' => dimensions
      )
    end.to_return(
      status: 200,
      body: {
        model: 'baai/bge-m3',
        usage: { prompt_tokens: 8 },
        data: [
          { index: 1, embedding: second_vector },
          { index: 0, embedding: vector }
        ]
      }.to_json,
      headers: { 'Content-Type' => 'application/json' }
    )

    result = described_class.embed(
      %w[first second],
      model: 'baai/bge-m3',
      dimensions: dimensions,
      api_key: 'openrouter-key'
    )

    expect(stub).to have_been_requested
    expect(result.vectors).to eq([vector, second_vector])
    expect(result.input_tokens).to eq(8)
    expect(result.model).to eq('baai/bge-m3')
  end

  it 'normalizes API bases before posting embeddings' do
    stub = stub_request(:post, 'https://openrouter.ai/api/v1/embeddings')
           .to_return(status: 200, body: { data: [{ embedding: vector }] }.to_json)

    result = described_class.embed(
      'hello',
      model: 'openai/text-embedding-3-small',
      dimensions: dimensions,
      api_key: 'openrouter-key',
      api_base: 'https://openrouter.ai/api/v1/models'
    )

    expect(stub).to have_been_requested
    expect(result.vectors).to eq([vector])
  end

  it 'raises a configuration error when the API key is missing' do
    expect do
      described_class.embed(
        'hello',
        model: 'openai/text-embedding-3-small',
        dimensions: dimensions,
        api_key: nil
      )
    end.to raise_error(RubyLLM::ConfigurationError, /OpenRouter API key is not configured for embeddings/)
  end

  it 'raises a RubyLLM unauthorized error for invalid OpenRouter keys' do
    stub_request(:post, 'https://openrouter.ai/api/v1/embeddings')
      .to_return(status: 401, body: { error: { message: 'Invalid key' } }.to_json)

    expect do
      described_class.embed(
        'hello',
        model: 'openai/text-embedding-3-small',
        dimensions: dimensions,
        api_key: 'bad-key'
      )
    end.to raise_error(RubyLLM::UnauthorizedError, /Invalid key/)
  end

  it 'raises a RubyLLM error for OpenRouter API errors' do
    stub_request(:post, 'https://openrouter.ai/api/v1/embeddings')
      .to_return(status: 400, body: { error: { message: 'bad model' } }.to_json)

    expect do
      described_class.embed(
        'hello',
        model: 'bad/model',
        dimensions: dimensions,
        api_key: 'openrouter-key'
      )
    end.to raise_error(RubyLLM::Error, /OpenRouter embedding failed: bad model/)
  end

  it 'raises a status error for non-JSON OpenRouter HTTP errors' do
    stub_request(:post, 'https://openrouter.ai/api/v1/embeddings')
      .to_return(status: [502, 'Bad Gateway'], body: '<html>bad gateway</html>')

    expect do
      described_class.embed(
        'hello',
        model: 'openai/text-embedding-3-small',
        dimensions: dimensions,
        api_key: 'openrouter-key'
      )
    end.to raise_error(RubyLLM::Error, /OpenRouter embedding failed: HTTP 502 Bad Gateway/)
  end

  it 'raises a RubyLLM error for invalid JSON success responses' do
    stub_request(:post, 'https://openrouter.ai/api/v1/embeddings')
      .to_return(status: 200, body: '<html>not-json</html>')

    expect do
      described_class.embed(
        'hello',
        model: 'openai/text-embedding-3-small',
        dimensions: dimensions,
        api_key: 'openrouter-key'
      )
    end.to raise_error(RubyLLM::Error, /OpenRouter embedding returned invalid JSON/)
  end

  it 'raises a RubyLLM error when the response does not include a vector' do
    stub_request(:post, 'https://openrouter.ai/api/v1/embeddings')
      .to_return(status: 200, body: { data: [{}] }.to_json)

    expect do
      described_class.embed(
        'hello',
        model: 'openai/text-embedding-3-small',
        dimensions: dimensions,
        api_key: 'openrouter-key'
      )
    end.to raise_error(RubyLLM::Error, /OpenRouter embedding response did not include a vector/)
  end

  it 'raises a RubyLLM error when the vector dimensions are unsupported' do
    stub_request(:post, 'https://openrouter.ai/api/v1/embeddings')
      .to_return(status: 200, body: { data: [{ embedding: [0.1, 0.2, 0.3] }] }.to_json)

    expect do
      described_class.embed(
        'hello',
        model: 'baai/bge-m3',
        dimensions: dimensions,
        api_key: 'openrouter-key'
      )
    end.to raise_error(RubyLLM::Error, %r{returned 3 dimensions for baai/bge-m3, expected #{dimensions}})
  end

  it 'raises a RubyLLM error for transport errors' do
    stub_request(:post, 'https://openrouter.ai/api/v1/embeddings')
      .to_raise(SocketError.new('getaddrinfo failed'))

    expect do
      described_class.embed(
        'hello',
        model: 'openai/text-embedding-3-small',
        dimensions: dimensions,
        api_key: 'openrouter-key'
      )
    end.to raise_error(RubyLLM::Error, /OpenRouter embedding request failed: getaddrinfo failed/)
  end
end
