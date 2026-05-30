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
      last_refresh_error: nil
    )
  end

  it 'summarizes key status, catalog counts, endpoint providers, and never returns secrets' do
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
end
