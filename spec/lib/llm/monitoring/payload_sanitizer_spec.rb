# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::Monitoring::PayloadSanitizer do
  describe '.call' do
    it 'redacts sensitive keys recursively and truncates large payloads' do
      sanitized = described_class.call(
        {
          'authorization' => 'Bearer super-secret',
          'nested' => {
            'api_key' => 'secret-key',
            'description' => 'x' * 2_100
          },
          'items' => Array.new(25) { |index| { 'token' => "secret-#{index}" } }
        }
      )

      expect(sanitized['authorization']).to eq('[REDACTED]')
      expect(sanitized.dig('nested', 'api_key')).to eq('[REDACTED]')
      expect(sanitized.dig('nested', 'description')).to end_with('...[TRUNCATED]')
      expect(sanitized['items'].length).to eq(21)
      expect(sanitized['items'].last).to eq('...[TRUNCATED]')
      expect(sanitized['items'].first['token']).to eq('[REDACTED]')
    end

    it 'keeps token usage counters because they are metrics, not secrets' do
      sanitized = described_class.call(
        {
          'prompt_tokens' => 120,
          'completion_tokens' => 40,
          'total_tokens' => 160,
          'thinking_tokens' => 12,
          'access_token' => 'secret-token'
        }
      )

      expect(sanitized['prompt_tokens']).to eq(120)
      expect(sanitized['completion_tokens']).to eq(40)
      expect(sanitized['total_tokens']).to eq(160)
      expect(sanitized['thinking_tokens']).to eq(12)
      expect(sanitized['access_token']).to eq('[REDACTED]')
    end

    it 'redacts bearer tokens and API keys embedded in string values' do
      sanitized = described_class.call(
        'request failed with Bearer sk-or-v1-secret, api_key=SECRET_VALUE and token: OTHER_SECRET'
      )

      expect(sanitized).to eq('request failed with Bearer [REDACTED], api_key=[REDACTED] and token: [REDACTED]')
    end

    it 'redacts raw content keys while preserving token usage counters' do
      sanitized = described_class.call(
        {
          'prompt' => 'private prompt',
          'messages' => [{ 'role' => 'user', 'content' => 'private text' }],
          'input' => 'private input',
          'output' => 'private output',
          'response' => 'private response',
          'raw_content' => 'private content',
          'output_tokens' => 5
        },
        redact_raw_content: true
      )

      expect(sanitized).to include(
        'prompt' => '[REDACTED]',
        'messages' => '[REDACTED]',
        'input' => '[REDACTED]',
        'output' => '[REDACTED]',
        'response' => '[REDACTED]',
        'raw_content' => '[REDACTED]',
        'output_tokens' => 5
      )
    end

    it 'bounds large hashes and reports omitted keys' do
      payload = 55.times.index_by { |index| "key_#{index}" }

      sanitized = described_class.call(payload)

      expect(sanitized.size).to eq(51)
      expect(sanitized['_truncated_keys_count']).to eq(5)
      expect(sanitized).to include('key_0' => 0, 'key_49' => 49)
      expect(sanitized).not_to have_key('key_50')
    end
  end
end
