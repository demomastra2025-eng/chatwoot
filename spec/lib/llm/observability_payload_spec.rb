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

  describe '.attach_provider_chat_response!' do
    it 'uses native inclusive token counts and cost without exporting the response body or reasoning' do
      raw = Struct.new(:body).new({
        'id' => 'gen-provider-usage', 'model' => 'openai/gpt-6-luna', 'provider' => 'Azure',
        'choices' => [{ 'message' => { 'content' => 'PRIVATE_DRAFT', 'reasoning' => 'PRIVATE_REASONING' } }],
        'usage' => {
          'prompt_tokens' => 100, 'completion_tokens' => 20, 'total_tokens' => 120, 'cost' => '0.0017',
          'prompt_tokens_details' => { 'cached_tokens' => 30 },
          'completion_tokens_details' => { 'reasoning_tokens' => 7 }, 'unknown_private_field' => 'PRIVATE_USAGE'
        }
      })
      response = RubyLLM::Message.new(role: :assistant, content: 'PRIVATE_DRAFT', input_tokens: 70,
                                     output_tokens: 13, thinking_tokens: 7, model_id: 'openai/gpt-6-luna', raw: raw)
      payload = { 'provider' => 'openrouter' }

      described_class.attach_provider_chat_response!(payload, response)

      expect(payload).to include('prompt_tokens' => 100, 'completion_tokens' => 20, 'total_tokens' => 120,
                                'thinking_tokens' => 7, 'cached_tokens' => 30, 'estimated_cost' => '0.0017',
                                'endpoint_provider' => 'Azure', 'openrouter_generation_id' => 'gen-provider-usage')
      expect(payload.to_json).not_to include('PRIVATE_DRAFT', 'PRIVATE_REASONING', 'PRIVATE_USAGE', 'choices', 'raw')
    end

    it 'preserves explicit zero cost and leaves missing or malformed cost unknown' do
      response = RubyLLM::Message.new(role: :assistant, content: 'Done', input_tokens: 5, output_tokens: 2,
                                     raw: Struct.new(:body).new({ 'usage' => { 'cost' => 0 } }))
      zero = described_class.attach_provider_chat_response!({ 'provider' => 'openrouter' }, response)
      expect(zero['estimated_cost']).to eq('0.0')

      [nil, 'not-a-number', 'NaN', '-1', { 'secret' => 'PRIVATE_COST' }].each do |cost|
        message = RubyLLM::Message.new(role: :assistant, content: 'Done', input_tokens: 5, output_tokens: 2,
                                      raw: Struct.new(:body).new({ 'usage' => { 'cost' => cost } }))
        payload = described_class.attach_provider_chat_response!({ 'provider' => 'openrouter' }, message)
        expect(payload).not_to have_key('estimated_cost')
        expect(payload.to_json).not_to include('PRIVATE_COST')
      end
    end
  end

  describe '.attach_chat_response!' do
    it 'extracts OpenRouter generation ids from response methods' do
      response = Struct.new(:content, :input_tokens, :output_tokens, :generation_id, :model_id, keyword_init: true)
                       .new(
                         content: 'Done', input_tokens: 3, output_tokens: 4,
                         generation_id: 'gen-method-123', model_id: 'openai/gpt-5.4'
                       )
      payload = { 'provider' => 'openrouter' }

      described_class.attach_chat_response!(payload, response)

      expect(payload).to include(
        'status' => 'success',
        'actual_model' => 'openai/gpt-5.4',
        'openrouter_generation_id' => 'gen-method-123'
      )
    end

    it 'extracts OpenRouter generation ids from the raw HTTP response body' do
      raw_response = Struct.new(:body).new({ 'id' => 'gen-body-123' })
      response = Struct.new(:content, :input_tokens, :output_tokens, :raw, keyword_init: true)
                       .new(content: 'Done', input_tokens: 3, output_tokens: 4, raw: raw_response)
      payload = { 'provider' => 'openrouter' }

      described_class.attach_chat_response!(payload, response)

      expect(payload['openrouter_generation_id']).to eq('gen-body-123')
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
