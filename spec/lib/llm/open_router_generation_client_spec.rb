# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::OpenRouterGenerationClient do
  it 'fetches and normalizes native OpenRouter generation metadata' do
    stub = stub_request(:get, 'https://openrouter.ai/api/v1/generation')
           .with(
             query: { 'id' => 'gen-123' },
             headers: { 'Authorization' => 'Bearer openrouter-key', 'Accept' => 'application/json' }
           )
           .to_return(
             status: 200,
             body: {
               data: {
                 id: 'gen-123',
                 provider_name: 'OpenAI',
                 model: 'openai/gpt-4o',
                 total_cost: '0.00042',
                 latency: 830,
                 finish_reason: 'stop',
                 tokens_prompt: 120,
                 tokens_completion: 40,
                 native_tokens_reasoning: 7,
                 cached_tokens: 13
               }
             }.to_json,
             headers: { 'Content-Type' => 'application/json' }
           )

    result = described_class.fetch(
      'gen-123',
      api_key: 'openrouter-key',
      api_base: 'https://openrouter.ai/api/v1'
    )

    expect(stub).to have_been_requested
    expect(result).to have_attributes(
      generation_id: 'gen-123',
      provider_name: 'OpenAI',
      model: 'openai/gpt-4o',
      cost: '0.00042',
      latency_ms: 830,
      finish_reason: 'stop',
      prompt_tokens: 120,
      completion_tokens: 40,
      reasoning_tokens: 7,
      cached_tokens: 13
    )
    expect(result.raw).to include('data' => include('id' => 'gen-123'))
  end

  it 'normalizes provider error metadata from completed OpenRouter generations' do
    stub_request(:get, 'https://openrouter.ai/api/v1/generation')
      .with(query: { 'id' => 'gen-error' })
      .to_return(
        status: 200,
        body: {
          data: {
            id: 'gen-error',
            finish_reason: 'error',
            error: { code: 'provider_error', message: 'Provider timed out' }
          }
        }.to_json
      )

    result = described_class.fetch('gen-error', api_key: 'openrouter-key')

    expect(result).to have_attributes(
      generation_id: 'gen-error',
      finish_reason: 'error',
      error_code: 'provider_error',
      error_reason: 'Provider timed out'
    )
  end

  it 'normalizes API bases before fetching generation metadata' do
    stub = stub_request(:get, 'https://openrouter.ai/api/v1/generation')
           .with(query: { 'id' => 'gen-123' })
           .to_return(status: 200, body: { data: { id: 'gen-123' } }.to_json)

    result = described_class.fetch(
      'gen-123',
      api_key: 'openrouter-key',
      api_base: 'https://openrouter.ai/api/v1/models'
    )

    expect(stub).to have_been_requested
    expect(result.generation_id).to eq('gen-123')
  end

  it 'raises a configuration error when the API key is missing' do
    expect do
      described_class.fetch('gen-123', api_key: nil)
    end.to raise_error(RubyLLM::ConfigurationError, /OpenRouter API key is not configured for generation metadata/)
  end

  it 'raises a configuration error when the generation id is missing' do
    expect do
      described_class.fetch(nil, api_key: 'openrouter-key')
    end.to raise_error(RubyLLM::ConfigurationError, /OpenRouter generation id is required/)
  end

  it 'raises a RubyLLM unauthorized error for invalid OpenRouter keys' do
    stub_request(:get, 'https://openrouter.ai/api/v1/generation')
      .with(query: { 'id' => 'gen-123' })
      .to_return(status: 401, body: { error: { message: 'Invalid key' } }.to_json)

    expect do
      described_class.fetch('gen-123', api_key: 'bad-key')
    end.to raise_error(RubyLLM::UnauthorizedError, /Invalid key/)
  end

  it 'raises a RubyLLM error for OpenRouter API errors' do
    stub_request(:get, 'https://openrouter.ai/api/v1/generation')
      .with(query: { 'id' => 'gen-123' })
      .to_return(status: 404, body: { error: { message: 'not found' } }.to_json)

    expect do
      described_class.fetch('gen-123', api_key: 'openrouter-key')
    end.to raise_error(RubyLLM::Error, /OpenRouter generation metadata failed: not found/)
  end

  it 'raises a status error for non-JSON OpenRouter HTTP errors' do
    stub_request(:get, 'https://openrouter.ai/api/v1/generation')
      .with(query: { 'id' => 'gen-123' })
      .to_return(status: [502, 'Bad Gateway'], body: '<html>bad gateway</html>')

    expect do
      described_class.fetch('gen-123', api_key: 'openrouter-key')
    end.to raise_error(RubyLLM::Error, /OpenRouter generation metadata failed: HTTP 502 Bad Gateway/)
  end

  it 'raises a RubyLLM error for invalid JSON success responses' do
    stub_request(:get, 'https://openrouter.ai/api/v1/generation')
      .with(query: { 'id' => 'gen-123' })
      .to_return(status: 200, body: '<html>not-json</html>')

    expect do
      described_class.fetch('gen-123', api_key: 'openrouter-key')
    end.to raise_error(RubyLLM::Error, /OpenRouter generation metadata returned invalid JSON/)
  end

  it 'raises a RubyLLM error for transport errors' do
    stub_request(:get, 'https://openrouter.ai/api/v1/generation')
      .with(query: { 'id' => 'gen-123' })
      .to_raise(SocketError.new('getaddrinfo failed'))

    expect do
      described_class.fetch('gen-123', api_key: 'openrouter-key')
    end.to raise_error(RubyLLM::Error, /OpenRouter generation metadata request failed: getaddrinfo failed/)
  end
end
