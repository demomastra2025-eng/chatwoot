# frozen_string_literal: true

require 'rails_helper'
require 'net/http'

RSpec.describe Llm::OpenRouterHeaders do
  describe '.build' do
    it 'disables response cache for privacy-sensitive requests even when the feature is cacheable' do
      result = described_class.build(
        cache_policy: 'read_only',
        native_endpoint: '/chat/completions',
        cache_options: { openrouter_response_cache: true },
        privacy_profile: 'sensitive',
        trace_capture_allowed: false
      )

      expect(result.headers).not_to include('X-OpenRouter-Cache')
      expect(result.metadata).to include(
        openrouter_response_cache: 'disabled',
        openrouter_response_cache_reason: 'privacy_sensitive'
      )
    end
  end

  describe '.apply!' do
    it 'preserves caller headers but does not let them override official attribution headers' do
      request = Net::HTTP::Post.new(URI('https://openrouter.ai/api/v1/embeddings'))

      described_class.apply!(
        request,
        headers: {
          'HTTP-Referer' => 'https://spoofed.example',
          'X-OpenRouter-Title' => 'Spoofed',
          'X-Test' => 'value'
        }
      )

      expect(request['HTTP-Referer']).to eq(described_class.attribution_headers['HTTP-Referer'])
      expect(request['X-OpenRouter-Title']).to eq('OneLink')
      expect(request['X-Test']).to eq('value')
    end
  end
end
