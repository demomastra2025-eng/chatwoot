# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Internal::FetchOpenRouterGenerationMetadataJob do
  let(:account) { create(:account) }
  let(:event) do
    create(
      :llm_event,
      account: account,
      provider: 'openrouter',
      model: 'openai/gpt-4o',
      prompt_tokens: 1,
      completion_tokens: 2,
      thinking_tokens: nil,
      total_tokens: 3,
      estimated_cost: nil,
      duration_ms: nil,
      payload: { 'openrouter_generation_id' => 'gen-123', 'status' => 'success' }
    )
  end
  let(:metadata) do
    Llm::OpenRouterGenerationClient::Result.new(
      generation_id: 'gen-123',
      provider_name: 'OpenAI',
      model: 'openai/gpt-4o-2026-05-30',
      cost: '0.00042',
      latency_ms: 830,
      finish_reason: 'stop',
      prompt_tokens: 120,
      completion_tokens: 40,
      reasoning_tokens: 7,
      cached_tokens: 13,
      raw: { 'data' => { 'id' => 'gen-123', 'provider_name' => 'OpenAI' } }
    )
  end

  before do
    allow(Llm::Config).to receive(:api_key).and_call_original
    allow(Llm::Config).to receive(:api_key).with('openrouter', account: account).and_return('openrouter-key')
    allow(Llm::Config).to receive(:api_base).and_call_original
    allow(Llm::Config).to receive(:api_base).with('openrouter', account: account).and_return('https://openrouter.ai/api/v1')
  end

  it 'fetches generation metadata asynchronously and enriches the llm event payload and columns' do
    expect(Llm::OpenRouterGenerationClient).to receive(:fetch).with(
      'gen-123',
      api_key: 'openrouter-key',
      api_base: 'https://openrouter.ai/api/v1'
    ).and_return(metadata)

    described_class.perform_now(event.id, 'gen-123')

    event.reload
    expect(event).to have_attributes(
      provider: 'openrouter',
      model: 'openai/gpt-4o-2026-05-30',
      reason: 'stop',
      prompt_tokens: 120,
      completion_tokens: 40,
      thinking_tokens: 7,
      total_tokens: 167,
      duration_ms: 830
    )
    expect(event.estimated_cost.to_f).to eq(0.00042)
    expect(event.payload).to include(
      'openrouter_generation_id' => 'gen-123',
      'endpoint_provider' => 'OpenAI',
      'openrouter_generation' => include(
        'id' => 'gen-123',
        'provider_name' => 'OpenAI',
        'model' => 'openai/gpt-4o-2026-05-30',
        'cost' => '0.00042',
        'latency_ms' => 830,
        'finish_reason' => 'stop',
        'prompt_tokens' => 120,
        'completion_tokens' => 40,
        'reasoning_tokens' => 7,
        'cached_tokens' => 13
      )
    )
    usage = LlmUsageEvent.find_by!(llm_event_id: event.id)
    expect(usage).to have_attributes(
      provider: 'openrouter',
      actual_provider: 'OpenAI',
      actual_model: 'openai/gpt-4o-2026-05-30',
      prompt_tokens: 120,
      completion_tokens: 40,
      reasoning_tokens: 7,
      cached_tokens: 13,
      total_tokens: 167,
      duration_ms: 830,
      generation_id: 'gen-123'
    )
    expect(usage.estimated_cost.to_f).to eq(0.00042)
  end

  it 'uses the generation id stored in the payload when no explicit id is passed' do
    expect(Llm::OpenRouterGenerationClient).to receive(:fetch).with(
      'gen-123',
      api_key: 'openrouter-key',
      api_base: 'https://openrouter.ai/api/v1'
    ).and_return(metadata)

    described_class.perform_now(event.id)
  end

  it 'sanitizes provider error reasons returned by generation metadata' do
    error_metadata = Llm::OpenRouterGenerationClient::Result.new(
      generation_id: 'gen-123',
      provider_name: 'OpenAI',
      model: 'openai/gpt-4o',
      error_code: 'provider_error',
      error_reason: 'failed with Bearer sk-or-v1-secret and api_key=SECRET_VALUE'
    )
    allow(Llm::OpenRouterGenerationClient).to receive(:fetch).and_return(error_metadata)

    described_class.perform_now(event.id, 'gen-123')

    event.reload
    expect(event.reason).to eq('failed with Bearer [REDACTED] and api_key=[REDACTED]')
    expect(event.payload.dig('openrouter_generation', 'error_reason')).to eq(
      'failed with Bearer [REDACTED] and api_key=[REDACTED]'
    )
  end

  it 'records compact generation metadata errors without re-raising' do
    allow(Llm::OpenRouterGenerationClient)
      .to receive(:fetch)
      .and_raise(RubyLLM::Error, 'upstream failed with Bearer sk-or-v1-secret and api_key=SECRET_VALUE')

    expect { described_class.perform_now(event.id, 'gen-123') }.not_to raise_error

    event.reload
    expect(event.payload).to include(
      'openrouter_generation_id' => 'gen-123',
      'openrouter_generation_error' => include(
        'generation_id' => 'gen-123',
        'error_class' => 'RubyLLM::Error',
        'message' => 'upstream failed with Bearer [REDACTED] and api_key=[REDACTED]',
        'openrouter_error_category' => 'provider_error',
        'retryable' => true
      )
    )
  end

  it 'skips missing events or blank generation ids' do
    no_generation_event = create(:llm_event, account: account, provider: 'openrouter', payload: {})

    expect(Llm::OpenRouterGenerationClient).not_to receive(:fetch)

    described_class.perform_now(-1, 'gen-missing-event')
    described_class.perform_now(no_generation_event.id)
  end
end
