# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::OpenRouterCapabilityResolver do
  before do
    upsert_installation_config('CAPTAIN_OPENROUTER_API_KEY', 'global-openrouter-key')
    allow(Llm::OpenRouterEndpointCatalog).to receive(:endpoint_metadata).and_return({})
  end

  describe '.call' do
    it 'allows an OpenRouter model that satisfies assistant requirements' do
      allow(Llm::OpenRouterModelCatalog).to receive(:model_configs).and_return(
        'openai/gpt-5.4' => {
          'provider' => 'openrouter',
          'type' => 'chat',
          'capabilities' => %w[text_input text_output structured_output tool_calling tool_choice streaming],
          'context_length' => 128_000
        }
      )

      result = described_class.call(model_id: 'openai/gpt-5.4', feature: :assistant)

      expect(result).to be_allowed
      expect(result.reasons).to be_empty
      expect(result.to_h).to include(
        model_id: 'openai/gpt-5.4',
        feature: 'assistant',
        allowed: true
      )
    end

    it 'requires explicit tool_choice support for assistant models' do
      allow(Llm::OpenRouterModelCatalog).to receive(:model_configs).and_return(
        'openrouter/owl-alpha' => {
          'provider' => 'openrouter',
          'type' => 'chat',
          'capabilities' => %w[text_input text_output structured_output tool_calling streaming]
        }
      )

      result = described_class.call(model_id: 'openrouter/owl-alpha', feature: :assistant)

      expect(result).not_to be_allowed
      expect(result.missing).to include('tool_choice')
      expect(result.reasons).to include(hash_including(code: 'tool_choice_unsupported'))
    end

    it 'requires reasoning only when Captain thinking effort is enabled' do
      allow(Llm::OpenRouterModelCatalog).to receive(:model_configs).and_return(
        'openai/gpt-no-reasoning' => {
          'provider' => 'openrouter',
          'type' => 'chat',
          'capabilities' => %w[text_input text_output structured_output tool_calling tool_choice streaming]
        }
      )

      expect(described_class.call(model_id: 'openai/gpt-no-reasoning', feature: :assistant)).to be_allowed

      result = described_class.call(
        model_id: 'openai/gpt-no-reasoning',
        feature: :assistant,
        runtime_preferences: { assistant_thinking_effort: 'low' }
      )

      expect(result).not_to be_allowed
      expect(result.missing).to include('reasoning')
      expect(result.reasons).to include(hash_including(code: 'reasoning_unsupported'))
    end

    it 'uses endpoint metadata to explain provider-level structured output gaps' do
      allow(Llm::OpenRouterModelCatalog).to receive(:model_configs).and_return(
        'openai/gpt-5.4' => {
          'provider' => 'openrouter',
          'type' => 'chat',
          'capabilities' => %w[text_input text_output structured_output tool_calling tool_choice streaming]
        }
      )
      allow(Llm::OpenRouterEndpointCatalog).to receive(:endpoint_metadata).with('openai/gpt-5.4').and_return(
        'providers' => ['Provider A'],
        'endpoints' => [
          {
            'provider_name' => 'Provider A',
            'capabilities' => %w[tool_calling streaming]
          }
        ]
      )

      result = described_class.call(model_id: 'openai/gpt-5.4', feature: :assistant)

      expect(result).not_to be_allowed
      expect(result.missing).to include('structured_output')
      expect(result.reasons).to include(hash_including(code: 'structured_output_unsupported'))
      expect(result.to_h).to include(endpoint_count: 1, endpoint_providers: ['Provider A'])
    end

    it 'fails clearly when ZDR-required privacy has no ZDR endpoint' do
      allow(Llm::OpenRouterModelCatalog).to receive(:model_configs).and_return(
        'openai/gpt-5.4' => {
          'provider' => 'openrouter',
          'type' => 'chat',
          'capabilities' => %w[text_input text_output structured_output tool_calling tool_choice streaming],
          'context_length' => 128_000
        }
      )
      allow(Llm::OpenRouterEndpointCatalog).to receive(:endpoint_metadata).with('openai/gpt-5.4').and_return(
        'providers' => ['Provider A'],
        'endpoints' => [
          {
            'provider_name' => 'Provider A',
            'capabilities' => %w[structured_output tool_calling tool_choice streaming],
            'zdr' => false
          }
        ]
      )

      result = described_class.call(
        model_id: 'openai/gpt-5.4',
        feature: :assistant,
        runtime_preferences: { privacy_profile: 'zdr_required' }
      )

      expect(result).not_to be_allowed
      expect(result.reasons).to include(hash_including(code: 'zdr_required_unsupported'))
    end

    it 'fails closed when ZDR-required privacy has no refreshed endpoint metadata' do
      allow(Llm::OpenRouterModelCatalog).to receive(:model_configs).and_return(
        'openai/gpt-5.4' => {
          'provider' => 'openrouter',
          'type' => 'chat',
          'capabilities' => %w[text_input text_output structured_output tool_calling tool_choice streaming],
          'context_length' => 128_000
        }
      )

      result = described_class.call(
        model_id: 'openai/gpt-5.4',
        feature: :assistant,
        runtime_preferences: { privacy_profile: 'zdr_required' }
      )

      expect(result).not_to be_allowed
      expect(result.reasons).to include(hash_including(code: 'zdr_required_unsupported'))
    end

    it 'reports invalid privacy profiles without masking the policy error' do
      allow(Llm::OpenRouterModelCatalog).to receive(:model_configs).and_return(
        'openai/gpt-5.4' => {
          'provider' => 'openrouter',
          'type' => 'chat',
          'capabilities' => %w[text_input text_output structured_output tool_calling tool_choice streaming],
          'context_length' => 128_000
        }
      )

      result = described_class.call(
        model_id: 'openai/gpt-5.4',
        feature: :assistant,
        runtime_preferences: { privacy_profile: 'collect_everything' }
      )

      expect(result).not_to be_allowed
      expect(result.reasons).to include(
        hash_including(code: 'privacy_profile_invalid', message: /Unsupported OpenRouter privacy profile/)
      )
    end

    it 'allows OpenRouter rerank models for knowledge rerank' do
      allow(Llm::OpenRouterModelCatalog).to receive(:model_configs).and_return(
        'cohere/rerank-v3.5' => {
          'provider' => 'openrouter',
          'type' => 'rerank',
          'capabilities' => %w[rerank text_input text_output]
        }
      )

      result = described_class.call(model_id: 'cohere/rerank-v3.5', feature: :knowledge_rerank)

      expect(result).to be_allowed
      expect(result.reasons).to be_empty
    end

    it 'reports missing provider credentials' do
      InstallationConfig.where(name: 'CAPTAIN_OPENROUTER_API_KEY').delete_all
      allow(Llm::OpenRouterModelCatalog).to receive(:model_configs).and_return(
        'openai/gpt-5.4' => {
          'provider' => 'openrouter',
          'type' => 'chat',
          'capabilities' => %w[structured_output tool_calling tool_choice streaming]
        }
      )

      result = described_class.call(model_id: 'openai/gpt-5.4', feature: :assistant)

      expect(result).not_to be_allowed
      expect(result.reasons).to include(hash_including(code: 'provider_not_configured'))
    end

    it 'reports direct providers as disabled for normal Captain features' do
      result = described_class.call(model_id: 'gpt-5.4', feature: :assistant)

      expect(result).not_to be_allowed
      expect(result.reasons).to include(hash_including(code: 'direct_provider_disabled'))
    end

    it 'reports Gemini direct models as voice-only in normal Captain settings' do
      result = described_class.call(model_id: 'gemini-2.5-pro', feature: :assistant)

      expect(result).not_to be_allowed
      expect(result.reasons).to include(hash_including(code: 'voice_only_provider'))
    end

    it 'reports embedding dimension mismatch and context limits for knowledge search runtime' do
      account = create(:account, captain_runtime: { 'knowledge_chunk_size' => 40_000 })
      allow(Llm::OpenRouterModelCatalog).to receive(:model_configs).and_return(
        'openai/text-embedding-small' => {
          'provider' => 'openrouter',
          'type' => 'embedding',
          'capabilities' => %w[embedding text_input],
          'embedding_dimensions' => 1024,
          'context_length' => 2000
        }
      )

      result = described_class.call(model_id: 'openai/text-embedding-small', feature: :help_center_search, account: account)

      expect(result).not_to be_allowed
      expect(result.reasons).to include(hash_including(code: 'embedding_dimension_mismatch'))
      expect(result.reasons).to include(hash_including(code: 'context_too_small'))
    end

    it 'fails closed for knowledge search embedding models with unknown context length' do
      allow(Llm::OpenRouterModelCatalog).to receive(:model_configs).and_return(
        'openai/text-embedding-unknown-context' => {
          'provider' => 'openrouter',
          'type' => 'embedding',
          'capabilities' => %w[embedding text_input],
          'embedding_dimensions' => Captain::KnowledgeSettings::VECTOR_DIMENSIONS
        }
      )

      result = described_class.call(model_id: 'openai/text-embedding-unknown-context', feature: :help_center_search)

      expect(result).not_to be_allowed
      expect(result.reasons).to include(hash_including(code: 'context_too_small'))
    end
  end
end
