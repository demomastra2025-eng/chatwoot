# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::OpenRouterRetryPolicy do
  def tool_with(metadata)
    Class.new do
      define_method(:tool_definition) { metadata }
      define_method(:name) { metadata[:id] || 'spec_tool' }
    end.new
  end

  it 'allows one immediate retry for OpenRouter no-content responses without tools' do
    policy = described_class.new(provider: 'openrouter', model: 'openai/gpt-5.4-mini')
    response = instance_double(RubyLLM::Message, content: '', tool_call?: false)

    expect(policy.retryable_response?(response, attempt: 1)).to have_attributes(
      retryable: true,
      reason: 'blank_response',
      category: 'no_content_generated',
      max_attempts: 2
    )
    expect(policy.retryable_response?(response, attempt: 2)).to have_attributes(
      retryable: false,
      reason: 'attempts_exhausted'
    )
  end

  it 'does not retry mutating tool flows to avoid duplicate side effects' do
    tool = tool_with(id: 'update_deal', risk_level: 'high', idempotent: false)
    policy = described_class.new(provider: 'openrouter', model: 'openai/gpt-5.4-mini', tools: [tool])
    error = RubyLLM::Error.new('OpenRouter provider error: 503 upstream unavailable')

    expect(policy.retryable_error?(error, attempt: 1)).to have_attributes(
      retryable: false,
      reason: 'unsafe_tool_flow',
      category: 'provider_error'
    )
  end

  it 'does not retry streaming requests or non-immediate retry-after rate limits' do
    streaming_policy = described_class.new(provider: 'openrouter', model: 'openai/gpt-5.4-mini', stream: true)
    rate_limit_policy = described_class.new(provider: 'openrouter', model: 'openai/gpt-5.4-mini')

    expect(streaming_policy.retryable_error?(RubyLLM::Error.new('Provider error 503'), attempt: 1))
      .to have_attributes(retryable: false, reason: 'streaming_request')
    expect(rate_limit_policy.retryable_error?(RubyLLM::RateLimitError.new('Rate limit exceeded. Retry after 30 seconds.'), attempt: 1))
      .to have_attributes(retryable: false, reason: 'rate_limited', category: 'rate_limited', retry_after_seconds: 30)
  end

  it 'allows immediate retry for transient provider errors on read-only tool flows' do
    tool = tool_with(id: 'lookup_contact', risk_level: 'low', read_only: true)
    policy = described_class.new(provider: 'openrouter', model: 'openai/gpt-5.4-mini', tools: [tool])
    error = RubyLLM::Error.new('OpenRouter provider error: 502 bad gateway')

    expect(policy.retryable_error?(error, attempt: 1)).to have_attributes(
      retryable: true,
      reason: 'provider_error',
      category: 'provider_error'
    )
  end
end
