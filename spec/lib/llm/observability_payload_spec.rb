# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::ObservabilityPayload do
  describe '.normalize' do
    it 'preserves whitelisted OpenRouter routing metadata for traces and usage ledger' do
      payload = described_class.normalize(
        {
          provider: 'openrouter',
          model: 'openai/gpt-5.4-mini',
          requested_model: 'openai/gpt-5.4-mini',
          routing_profile: 'exacto',
          openrouter_provider_order: ['OpenAI'],
          openrouter_require_parameters: true,
          openrouter_allow_fallbacks: false,
          openrouter_plugins: ['response-healing'],
          metadata: {
            openrouter_native_endpoint: '/embeddings',
            openrouter_allow_fallbacks: true,
            api_key: 'must-not-leak'
          }
        },
        runtime_mode: 'openrouter_runtime'
      )

      expect(payload).to include(
        requested_model: 'openai/gpt-5.4-mini',
        routing_profile: 'exacto',
        openrouter_provider_order: ['OpenAI'],
        openrouter_require_parameters: true,
        openrouter_allow_fallbacks: false,
        openrouter_plugins: ['response-healing'],
        openrouter_native_endpoint: '/embeddings'
      )
      expect(payload).not_to have_key(:api_key)
    end
  end

  describe '.attach_error!' do
    it 'adds OpenRouter error taxonomy fields for provider errors' do
      payload = { 'provider' => 'openrouter' }
      error = RubyLLM::RateLimitError.new('Rate limit exceeded. Retry after 12 seconds.')

      described_class.attach_error!(payload, error)

      expect(payload).to include(
        'status' => 'error',
        'openrouter_error_category' => 'rate_limited',
        'retryable' => true,
        'retry_after_seconds' => 12
      )
    end

    it 'redacts secrets embedded in error messages before storing observability payloads' do
      payload = { 'provider' => 'openrouter' }
      error = RubyLLM::Error.new('request failed with Bearer sk-or-v1-secret and api_key=SECRET_VALUE')

      described_class.attach_error!(payload, error)

      expect(payload['error_message']).to eq('request failed with Bearer [REDACTED] and api_key=[REDACTED]')
    end
  end

  describe '.attach_chat_response!' do
    it 'extracts OpenRouter generation ids from response methods' do
      response = Struct.new(:content, :input_tokens, :output_tokens, :generation_id, keyword_init: true)
                       .new(content: 'Done', input_tokens: 3, output_tokens: 4, generation_id: 'gen-method-123')
      payload = { 'provider' => 'openrouter' }

      described_class.attach_chat_response!(payload, response)

      expect(payload).to include(
        'status' => 'success',
        'openrouter_generation_id' => 'gen-method-123'
      )
    end

    it 'extracts OpenRouter generation ids from raw response metadata' do
      response = Struct.new(:content, :input_tokens, :output_tokens, :raw, keyword_init: true)
                       .new(content: 'Done', input_tokens: 3, output_tokens: 4, raw: { 'data' => { 'id' => 'gen-raw-123' } })
      payload = { 'provider' => 'openrouter' }

      described_class.attach_chat_response!(payload, response)

      expect(payload['openrouter_generation_id']).to eq('gen-raw-123')
    end

    it 'extracts OpenRouter generation ids from official response headers' do
      response = Struct.new(:content, :input_tokens, :output_tokens, :headers, keyword_init: true)
                       .new(content: 'Done', input_tokens: 3, output_tokens: 4, headers: { 'X-Generation-Id' => 'gen-header-123' })
      payload = { 'provider' => 'openrouter' }

      described_class.attach_chat_response!(payload, response)

      expect(payload['openrouter_generation_id']).to eq('gen-header-123')
    end

    it 'does not recurse forever when OpenRouter raw metadata contains a cycle' do
      raw = {}
      raw['data'] = raw
      response = Struct.new(:content, :input_tokens, :output_tokens, :raw, keyword_init: true)
                       .new(content: 'Done', input_tokens: 3, output_tokens: 4, raw: raw)
      payload = { 'provider' => 'openrouter' }

      expect { described_class.attach_chat_response!(payload, response) }.not_to raise_error

      expect(payload).to include('status' => 'success')
      expect(payload).not_to have_key('openrouter_generation_id')
    end

    it 'bounds OpenRouter generation id metadata search depth' do
      too_deep = { 'id' => 'gen-too-deep-123' }
      20.times { too_deep = { 'data' => too_deep } }
      response = Struct.new(:content, :input_tokens, :output_tokens, :raw, keyword_init: true)
                       .new(content: 'Done', input_tokens: 3, output_tokens: 4, raw: too_deep)
      payload = { 'provider' => 'openrouter' }

      described_class.attach_chat_response!(payload, response)

      expect(payload).not_to have_key('openrouter_generation_id')
    end

    it 'extracts OpenRouter generation ids from bounded array metadata' do
      response = Struct.new(:content, :input_tokens, :output_tokens, :raw, keyword_init: true)
                       .new(content: 'Done', input_tokens: 3, output_tokens: 4, raw: { 'candidates' => [{ 'data' => { 'id' => 'gen-array-123' } }] })
      payload = { 'provider' => 'openrouter' }

      described_class.attach_chat_response!(payload, response)

      expect(payload['openrouter_generation_id']).to eq('gen-array-123')
    end

    it 'does not label direct-provider response ids as OpenRouter generation ids' do
      response = Struct.new(:content, :input_tokens, :output_tokens, :id, keyword_init: true)
                       .new(content: 'Done', input_tokens: 3, output_tokens: 4, id: 'direct-response-id')
      payload = { 'provider' => 'openai' }

      described_class.attach_chat_response!(payload, response)

      expect(payload).not_to have_key('openrouter_generation_id')
    end
  end
end
