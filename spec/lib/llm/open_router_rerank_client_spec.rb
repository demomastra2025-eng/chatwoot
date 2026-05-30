# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::OpenRouterRerankClient do
  it 'posts a rerank request to the native OpenRouter rerank endpoint' do
    stub = stub_request(:post, 'https://openrouter.ai/api/v1/rerank')
           .with(headers: { 'Authorization' => 'Bearer openrouter-key', 'Accept' => 'application/json' }) do |request|
      body = JSON.parse(request.body)
      expect(body).to include(
        'model' => 'cohere/rerank-v3.5',
        'query' => 'refund policy',
        'documents' => ['refunds are available', 'shipping policy'],
        'top_n' => 1,
        'return_documents' => true
      )
    end.to_return(
      status: 200,
      body: {
        model: 'cohere/rerank-v3.5',
        usage: { prompt_tokens: 12 },
        results: [
          { index: 0, relevance_score: 0.97, document: { text: 'refunds are available' } }
        ]
      }.to_json,
      headers: { 'Content-Type' => 'application/json' }
    )

    result = described_class.rerank(
      query: 'refund policy',
      documents: ['refunds are available', 'shipping policy'],
      model: 'cohere/rerank-v3.5',
      top_n: 1,
      api_key: 'openrouter-key',
      api_base: 'https://openrouter.ai/api/v1'
    )

    expect(stub).to have_been_requested
    expect(result.model).to eq('cohere/rerank-v3.5')
    expect(result.usage).to eq('prompt_tokens' => 12)
    expect(result.results.first).to have_attributes(index: 0, relevance_score: 0.97, document: { 'text' => 'refunds are available' })
  end

  it 'normalizes API bases before posting rerank requests' do
    stub = stub_request(:post, 'https://openrouter.ai/api/v1/rerank')
           .to_return(status: 200, body: { results: [{ index: 0, score: 0.7 }] }.to_json)

    result = described_class.rerank(
      query: 'refund policy',
      documents: ['refunds are available'],
      model: 'cohere/rerank-v3.5',
      api_key: 'openrouter-key',
      api_base: 'https://openrouter.ai/api/v1/models'
    )

    expect(stub).to have_been_requested
    expect(result.results.first.relevance_score).to eq(0.7)
  end

  it 'raises a configuration error when the API key is missing' do
    expect do
      described_class.rerank(
        query: 'refund policy',
        documents: ['refunds are available'],
        model: 'cohere/rerank-v3.5',
        api_key: nil
      )
    end.to raise_error(RubyLLM::ConfigurationError, /OpenRouter API key is not configured for rerank/)
  end

  it 'raises an argument error when required request fields are missing' do
    expect do
      described_class.rerank(query: '', documents: ['refunds are available'], model: 'cohere/rerank-v3.5', api_key: 'key')
    end.to raise_error(ArgumentError, /query is required/)

    expect do
      described_class.rerank(query: 'refund policy', documents: [], model: 'cohere/rerank-v3.5', api_key: 'key')
    end.to raise_error(ArgumentError, /documents are required/)
  end

  it 'raises a RubyLLM unauthorized error for invalid OpenRouter keys' do
    stub_request(:post, 'https://openrouter.ai/api/v1/rerank')
      .to_return(status: 401, body: { error: { message: 'Invalid key' } }.to_json)

    expect do
      described_class.rerank(
        query: 'refund policy',
        documents: ['refunds are available'],
        model: 'cohere/rerank-v3.5',
        api_key: 'bad-key'
      )
    end.to raise_error(RubyLLM::UnauthorizedError, /Invalid key/)
  end

  it 'raises a RubyLLM error for OpenRouter API errors' do
    stub_request(:post, 'https://openrouter.ai/api/v1/rerank')
      .to_return(status: 400, body: { error: { message: 'bad model' } }.to_json)

    expect do
      described_class.rerank(
        query: 'refund policy',
        documents: ['refunds are available'],
        model: 'bad/model',
        api_key: 'openrouter-key'
      )
    end.to raise_error(RubyLLM::Error, /OpenRouter rerank failed: bad model/)
  end

  it 'raises a status error for non-JSON OpenRouter HTTP errors' do
    stub_request(:post, 'https://openrouter.ai/api/v1/rerank')
      .to_return(status: [502, 'Bad Gateway'], body: '<html>bad gateway</html>')

    expect do
      described_class.rerank(
        query: 'refund policy',
        documents: ['refunds are available'],
        model: 'cohere/rerank-v3.5',
        api_key: 'openrouter-key'
      )
    end.to raise_error(RubyLLM::Error, /OpenRouter rerank failed: HTTP 502 Bad Gateway/)
  end

  it 'raises a RubyLLM error for invalid JSON success responses' do
    stub_request(:post, 'https://openrouter.ai/api/v1/rerank')
      .to_return(status: 200, body: '<html>not-json</html>')

    expect do
      described_class.rerank(
        query: 'refund policy',
        documents: ['refunds are available'],
        model: 'cohere/rerank-v3.5',
        api_key: 'openrouter-key'
      )
    end.to raise_error(RubyLLM::Error, /OpenRouter rerank returned invalid JSON/)
  end

  it 'raises a RubyLLM error when the response does not include ranked results' do
    stub_request(:post, 'https://openrouter.ai/api/v1/rerank')
      .to_return(status: 200, body: { results: [{}] }.to_json)

    expect do
      described_class.rerank(
        query: 'refund policy',
        documents: ['refunds are available'],
        model: 'cohere/rerank-v3.5',
        api_key: 'openrouter-key'
      )
    end.to raise_error(RubyLLM::Error, /result did not include an index/)
  end

  it 'raises a RubyLLM error for transport errors' do
    stub_request(:post, 'https://openrouter.ai/api/v1/rerank')
      .to_raise(SocketError.new('getaddrinfo failed'))

    expect do
      described_class.rerank(
        query: 'refund policy',
        documents: ['refunds are available'],
        model: 'cohere/rerank-v3.5',
        api_key: 'openrouter-key'
      )
    end.to raise_error(RubyLLM::Error, /OpenRouter rerank request failed: getaddrinfo failed/)
  end
end
