# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::OpenRouterDiagnostics do
  let(:model_configs) do
    {
      'openai/gpt-5.4' => {
        'provider' => 'openrouter',
        'display_name' => 'GPT-5.4',
        'type' => 'chat',
        'capabilities' => %w[text_input text_output tool_calling structured_output reasoning image_input],
        'context_length' => 128_000
      },
      'openai/gpt-audio-mini' => {
        'provider' => 'openrouter',
        'display_name' => 'GPT Audio Mini',
        'type' => 'chat',
        'capabilities' => %w[audio_input text_output transcription],
        'context_length' => 64_000
      },
      'openai/text-embedding-3-small' => {
        'provider' => 'openrouter',
        'display_name' => 'Text Embedding 3 Small',
        'type' => 'embedding',
        'capabilities' => %w[embedding text_input],
        'context_length' => 8191,
        'embedding_dimensions' => Captain::KnowledgeSettings::VECTOR_DIMENSIONS
      }
    }
  end

  let(:endpoint_configs) do
    {
      'openai/gpt-5.4' => {
        'model_id' => 'openai/gpt-5.4',
        'providers' => %w[OpenAI Acme],
        'endpoints' => [
          { 'provider_name' => 'OpenAI', 'capabilities' => %w[tool_calling structured_output reasoning], 'zdr' => true, 'data_collection' => 'deny' },
          { 'provider_name' => 'Acme', 'capabilities' => %w[tool_calling structured_output], 'zdr' => false, 'data_collection' => 'allow' }
        ]
      },
      'openai/gpt-audio-mini' => {
        'model_id' => 'openai/gpt-audio-mini',
        'providers' => %w[OpenAI],
        'endpoints' => [
          { 'provider_name' => 'OpenAI', 'capabilities' => %w[audio_input], 'zdr' => false, 'data_collection' => 'deny' }
        ]
      }
    }
  end

  before do
    upsert_installation_config('CAPTAIN_OPENROUTER_API_KEY', 'test-openrouter-diagnostics-key')
    allow(Llm::OpenRouterModelCatalog).to receive(:model_configs).and_return(model_configs)
    allow(Llm::OpenRouterModelCatalog).to receive(:metadata).and_return(
      total_models: 3,
      chat_models: 2,
      transcription_models: 0,
      embedding_models: 1,
      rerank_models: 0,
      source: 'openrouter_api',
      using_fallback: false,
      fallback_models: 0,
      last_refreshed_at: '2026-05-30T12:00:00Z',
      last_refresh_error: nil
    )
    allow(Llm::OpenRouterEndpointCatalog).to receive(:endpoint_configs).and_return(endpoint_configs)
    allow(Llm::OpenRouterEndpointCatalog).to receive(:metadata).and_return(
      total_models: 2,
      total_endpoints: 3,
      provider_count: 2,
      providers: %w[Acme OpenAI],
      source: 'openrouter_api',
      last_refreshed_at: '2026-05-30T12:01:00Z',
      last_refresh_error: nil,
      pending_model_count: 1,
      pending_model_ids: ['meta-llama/llama-4']
    )
  end

  it 'summarizes key status, catalog counts, endpoint providers, runtime telemetry, and never returns secrets' do
    create(
      :llm_event,
      provider: 'openrouter',
      feature: 'assistant',
      model: 'openai/gpt-5.4',
      event_name: 'llm.chat.complete',
      status: 'failed',
      error: true,
      error_code: 'provider_unavailable',
      tool_failure: true,
      schema_invalid: true,
      total_tokens: 1_200,
      duration_ms: 850,
      estimated_cost: 0.0123,
      created_at: 2.hours.ago
    )
    create(
      :llm_event,
      provider: 'openrouter',
      feature: 'knowledge',
      model: 'openai/text-embedding-3-small',
      event_name: 'llm.embedding.complete',
      total_tokens: 80,
      estimated_cost: 0.0002,
      created_at: 1.hour.ago
    )
    create(:llm_event, provider: 'openai', feature: 'assistant', error: true, created_at: 30.minutes.ago)
    create(:llm_event, provider: 'openrouter', feature: 'assistant', created_at: 2.days.ago)
    create(
      :llm_usage_event,
      provider: 'openrouter',
      feature: 'assistant',
      estimated_cost: 0.50,
      total_tokens: 100,
      cached_tokens: 10,
      reasoning_tokens: 4,
      occurred_at: 30.minutes.ago
    )

    diagnostics = described_class.call(sample_limit: 2)

    expect(diagnostics.dig(:key_status, :effective_configured)).to be true
    expect(diagnostics.dig(:key_status, :global_configured)).to be true
    expect(diagnostics.dig(:catalog, :counts_by_type)).to include(chat: 2, embedding: 1)
    expect(diagnostics.dig(:catalog, :capability_counts)).to include(
      tool_calling: 1,
      structured_output: 1,
      image_input: 1,
      audio_input: 1,
      embedding: 1
    )
    expect(diagnostics.dig(:endpoints, :provider_counts)).to include('OpenAI' => 2, 'Acme' => 1)
    expect(diagnostics.dig(:endpoints, :pending_model_count)).to eq(1)
    expect(diagnostics.dig(:endpoints, :pending_model_ids)).to eq(['meta-llama/llama-4'])
    expect(diagnostics.dig(:runtime, :provider)).to eq('openrouter')
    expect(diagnostics.dig(:runtime, :total_events)).to eq(2)
    expect(diagnostics.dig(:runtime, :request_count)).to eq(1)
    expect(diagnostics.dig(:runtime, :error_count)).to eq(1)
    expect(diagnostics.dig(:runtime, :tool_failure_count)).to eq(1)
    expect(diagnostics.dig(:runtime, :schema_invalid_count)).to eq(1)
    expect(diagnostics.dig(:runtime, :provider_failure_count)).to eq(1)
    expect(diagnostics.dig(:runtime, :total_tokens)).to eq(1280)
    expect(diagnostics.dig(:runtime, :by_feature)).to include('assistant' => 1, 'knowledge' => 1)
    expect(diagnostics.dig(:runtime, :recent_error_codes)).to include('provider_unavailable' => 1)
    expect(diagnostics.dig(:usage, :request_count)).to eq(1)
    expect(diagnostics.dig(:usage, :total_tokens)).to eq(100)
    expect(diagnostics.dig(:usage, :cached_tokens)).to eq(10)
    expect(diagnostics.dig(:usage, :reasoning_tokens)).to eq(4)
    expect(diagnostics.dig(:usage, :estimated_cost)).to eq(0.5)
    expect(diagnostics.to_json).not_to include('test-openrouter-diagnostics-key')
  end

  it 'includes workspace policy and guardrail diagnostics' do
    diagnostics = described_class.call(sample_limit: 2)

    expect(diagnostics.dig(:workspace_policy, :privacy_profile)).to eq('standard')
    expect(diagnostics.dig(:workspace_policy, :provider_preferences)).to include(
      allow_fallbacks: true,
      data_collection: 'deny',
      zdr: false
    )
    expect(diagnostics.dig(:workspace_policy, :guardrails, :prompt_injection)).to include(status: 'evaluation_required')
    expect(diagnostics.dig(:guardrails, :features, 'assistant', :server_tools)).to include(status: 'allowlist_enforced')
    expect(diagnostics.dig(:guardrails, :features, 'editor', :plugins)).to include(status: 'blocked_by_default')
    expect(diagnostics.dig(:guardrails, :status_counts)).to include('evaluation_required')
    expect(diagnostics.dig(:features, 'assistant', :policy, :allowed_server_tools)).to include('openrouter:datetime')
    expect(diagnostics.dig(:features, 'editor', :policy, :compiled_service_tier)).to eq('flex')
  end

  it 'prioritizes selected models in the model eligibility sample' do
    allow(Llm::Config).to receive(:model_for).and_call_original
    allow(Llm::Config).to receive(:model_for).with(feature: 'assistant', account: nil).and_return('openai/gpt-audio-mini')

    diagnostics = described_class.call(sample_limit: 1)

    expect(diagnostics[:model_eligibility].first[:id]).to eq('openai/gpt-audio-mini')
  end

  it 'includes sampled model eligibility diagnostics for hidden reasons' do
    diagnostics = described_class.call(sample_limit: 3)

    audio_model = diagnostics[:model_eligibility].find { |model| model[:id] == 'openai/gpt-audio-mini' }
    expect(audio_model).to be_present

    assistant_diagnostics = audio_model.dig(:features, 'assistant')
    expect(assistant_diagnostics[:allowed]).to be false
    expect(assistant_diagnostics[:reason_codes]).to include('structured_output_unsupported', 'tool_calling_unsupported')
  end

  it 'evaluates nested diagnostics inside per-request config and OpenRouter catalog snapshots' do
    runtime_cache_seen = false
    model_snapshot_seen = false
    endpoint_snapshot_seen = false

    allow(Llm::Config).to receive(:provider_available?).and_wrap_original do |method, *args, **kwargs|
      runtime_cache_seen ||= Thread.current[Llm::Config::RUNTIME_CACHE_KEY].present?
      method.call(*args, **kwargs)
    end
    allow(Llm::OpenRouterCapabilityResolver).to receive(:call).and_wrap_original do |method, *args, **kwargs|
      model_snapshot_seen ||= Llm::OpenRouterModelCatalog.send(:current_model_configs_snapshot).present?
      endpoint_snapshot_seen ||= Llm::OpenRouterEndpointCatalog.send(:current_endpoint_configs_snapshot).present?
      method.call(*args, **kwargs)
    end

    described_class.call(sample_limit: 1)

    expect(runtime_cache_seen).to be true
    expect(model_snapshot_seen).to be true
    expect(endpoint_snapshot_seen).to be true
  end
end
