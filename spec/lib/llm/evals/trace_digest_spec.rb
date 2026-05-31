# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::Evals::TraceDigest do
  it 'builds a sanitized compact digest from event hashes' do
    digest = described_class.new(
      events: [
        {
          event_name: 'llm.chat.complete',
          tool_name: 'search_deals',
          prompt_tokens: 10,
          completion_tokens: 5,
          payload: {
            openrouter_generation_id: 'gen_123',
            authorization: 'Bearer secret-token',
            nested: { api_key: 'abc', value: 'safe' }
          }
        },
        {
          event_name: 'llm.tool.complete',
          error: true,
          payload: { status: 'failed', token: 'secret' }
        }
      ]
    ).call

    expect(digest).to include(
      total_count: 2,
      included_count: 2,
      tool_names: ['search_deals'],
      error_count: 1,
      openrouter_generation_ids: ['gen_123'],
      token_totals: include(prompt_tokens: 10, completion_tokens: 5)
    )
    expect(digest[:events].first[:payload]).to include(
      authorization: '[REDACTED]',
      nested: include(api_key: '[REDACTED]', value: 'safe')
    )
  end

  it 'keeps token usage counters while redacting credential-like token fields' do
    digest = described_class.new(
      events: [
        {
          event_name: 'llm.chat.complete',
          payload: {
            total_tokens: 42,
            access_token: 'secret'
          }
        }
      ]
    ).call

    expect(digest[:token_totals]).to include(total_tokens: 42)
    expect(digest.dig(:events, 0, :payload)).to include(total_tokens: 42, access_token: '[REDACTED]')
  end
end
