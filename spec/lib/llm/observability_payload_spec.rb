# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::ObservabilityPayload do
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

    it 'does not label direct-provider response ids as OpenRouter generation ids' do
      response = Struct.new(:content, :input_tokens, :output_tokens, :id, keyword_init: true)
                       .new(content: 'Done', input_tokens: 3, output_tokens: 4, id: 'direct-response-id')
      payload = { 'provider' => 'openai' }

      described_class.attach_chat_response!(payload, response)

      expect(payload).not_to have_key('openrouter_generation_id')
    end
  end
end
