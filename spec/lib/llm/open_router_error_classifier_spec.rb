# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::OpenRouterErrorClassifier do
  describe '.classify' do
    it 'classifies missing configuration as non-retryable' do
      result = described_class.classify(RubyLLM::ConfigurationError.new('OpenRouter API key is not configured.'))

      expect(result).to have_attributes(
        category: 'configuration_missing',
        retryable: false,
        retry_after_seconds: nil
      )
    end

    it 'classifies invalid keys distinctly from generic provider errors' do
      result = described_class.classify(RubyLLM::UnauthorizedError.new('Invalid API key'))

      expect(result).to have_attributes(category: 'invalid_api_key', retryable: false)
    end

    it 'honors retry-after hints for OpenRouter rate limits' do
      result = described_class.classify(RubyLLM::RateLimitError.new('Rate limit exceeded. Retry after 17 seconds.'))

      expect(result).to have_attributes(
        category: 'rate_limited',
        retryable: true,
        retry_after_seconds: 17
      )
    end

    it 'detects strict routing and required-parameter failures' do
      error = RubyLLM::Error.new('No endpoints found that support all requested parameters for this model.')

      expect(described_class.classify(error)).to have_attributes(
        category: 'routing_requirements_unsatisfied',
        retryable: false
      )
    end

    it 'detects insufficient credits without marking the request retryable' do
      error = RubyLLM::Error.new('OpenRouter request failed: insufficient credits')

      expect(described_class.classify(error)).to have_attributes(
        category: 'insufficient_credits',
        retryable: false
      )
    end

    it 'detects provider invalid-response and no-content classes' do
      invalid = RubyLLM::Error.new('OpenRouter embedding response did not include a vector.')
      empty = RubyLLM::Error.new('OpenRouter chat completion returned no content.')

      expect(described_class.classify(invalid).category).to eq('provider_invalid_response')
      expect(described_class.classify(empty).category).to eq('no_content_generated')
    end
  end
end
