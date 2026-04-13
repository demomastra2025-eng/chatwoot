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
            'content' => 'x' * 2_100
          },
          'items' => Array.new(25) { |index| { 'token' => "secret-#{index}" } }
        }
      )

      expect(sanitized['authorization']).to eq('[REDACTED]')
      expect(sanitized.dig('nested', 'api_key')).to eq('[REDACTED]')
      expect(sanitized.dig('nested', 'content')).to end_with('...[TRUNCATED]')
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
          'access_token' => 'secret-token'
        }
      )

      expect(sanitized['prompt_tokens']).to eq(120)
      expect(sanitized['completion_tokens']).to eq(40)
      expect(sanitized['total_tokens']).to eq(160)
      expect(sanitized['access_token']).to eq('[REDACTED]')
    end
  end
end
