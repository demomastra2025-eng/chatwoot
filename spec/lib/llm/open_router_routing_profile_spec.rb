# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::OpenRouterRoutingProfile do
  describe '.for' do
    it 'builds a tool-safe low-latency Captain agent routing profile' do
      profile = described_class.for(feature: :captain_agent, model: 'moonshotai/kimi-k2.6')

      expect(profile.feature_key).to eq('captain_agent')
      expect(profile.models).to start_with('moonshotai/kimi-k2.6')
      expect(profile.provider_preferences).to include(
        require_parameters: true,
        allow_fallbacks: true,
        data_collection: 'deny',
        sort: { by: 'latency', partition: 'none' },
        preferred_max_latency: { p90: 3 }
      )
      expect(profile.to_h).to include(
        models: profile.models,
        provider: profile.provider_preferences
      )
    end

    it 'uses a latency-first profile for Copilot interactive chat' do
      profile = described_class.for(feature: :copilot, model: 'openai/gpt-5.4')

      expect(profile.provider_preferences).to include(
        require_parameters: true,
        allow_fallbacks: true,
        sort: { by: 'latency', partition: 'none' }
      )
      expect(profile.models).to start_with('openai/gpt-5.4')
    end

    it 'uses cost/speed routing for background editor and label features' do
      editor_profile = described_class.for(feature: :editor, model: 'openai/gpt-5.4-mini')
      label_profile = described_class.for(feature: :label_suggestion, model: 'openai/gpt-5.4-mini')

      expect(editor_profile.provider_preferences).to include(sort: { by: 'price', partition: 'none' })
      expect(label_profile.provider_preferences).to include(sort: { by: 'price', partition: 'none' })
      expect(editor_profile.provider_preferences[:require_parameters]).to be(false)
    end

    it 'marks native endpoint profiles for embeddings, transcription, and rerank' do
      expect(described_class.for(feature: :embedding, model: 'openai/text-embedding-3-small').native_endpoint).to eq('/embeddings')
      expect(described_class.for(feature: :audio_transcription,
                                 model: 'openai/gpt-4o-mini-transcribe').native_endpoint).to eq('/audio/transcriptions')
      expect(described_class.for(feature: :knowledge_rerank, model: 'rerank/model').native_endpoint).to eq('/rerank')
    end

    it 'emits explicit sensitive privacy policy for account runtime preferences' do
      account = instance_double(Account, captain_preferences: { runtime: { privacy_profile: 'sensitive' } })

      profile = described_class.for(feature: :captain_agent, model: 'moonshotai/kimi-k2.6', account: account)

      expect(profile.provider_preferences).to include(
        allow_fallbacks: true,
        data_collection: 'deny',
        zdr: false
      )
    end

    it 'fails closed for ZDR-required account runtime preferences' do
      account = instance_double(Account, captain_preferences: { runtime: { privacy_profile: 'zdr_required' } })

      profile = described_class.for(feature: :captain_agent, model: 'moonshotai/kimi-k2.6', account: account)

      expect(profile.provider_preferences).to include(
        allow_fallbacks: false,
        data_collection: 'deny',
        zdr: true
      )
    end

    it 'supports explicit Exacto provider order as a policy-level routing strategy' do
      profile = described_class.for(
        feature: :captain_agent,
        model: 'openai/gpt-5.4',
        runtime_preferences: {
          openrouter_routing_strategy: 'exacto',
          openrouter_provider_order: %w[OpenAI Anthropic]
        }
      )

      expect(profile.provider_preferences).to include(
        order: %w[OpenAI Anthropic],
        allow_fallbacks: false,
        require_parameters: true
      )
    end

    it 'supports Auto Exacto provider order with fallback routing enabled' do
      profile = described_class.for(
        feature: :copilot,
        model: 'openai/gpt-5.4',
        runtime_preferences: {
          openrouter_routing_strategy: 'auto_exacto',
          openrouter_provider_order: %w[OpenAI Anthropic]
        }
      )

      expect(profile.provider_preferences).to include(
        order: %w[OpenAI Anthropic],
        allow_fallbacks: true,
        require_parameters: true
      )
      expect(profile.provider_preferences).not_to include(:sort)
    end

    it 'exposes Exacto routing policy metadata for admin/debug previews' do
      profile = described_class.for(
        feature: :captain_agent,
        model: 'openai/gpt-5.4',
        runtime_preferences: {
          openrouter_routing_strategy: 'auto-exacto',
          openrouter_provider_order: %w[OpenAI Anthropic]
        }
      )

      expect(profile.routing_policy).to include(
        strategy: 'auto_exacto',
        provider_order: %w[OpenAI Anthropic],
        allow_fallbacks: true,
        require_parameters: true
      )
      expect(profile.routing_policy).not_to include(:sort)
      expect(profile.to_h).to include(routing_policy: profile.routing_policy)
    end

    it 'ignores Exacto strategies without a non-empty provider order' do
      exacto_profile = described_class.for(
        feature: :captain_agent,
        model: 'openai/gpt-5.4',
        runtime_preferences: {
          openrouter_routing_strategy: 'exacto',
          openrouter_provider_order: []
        }
      )
      auto_exacto_profile = described_class.for(
        feature: :copilot,
        model: 'openai/gpt-5.4',
        runtime_preferences: {
          openrouter_routing_strategy: 'auto-exacto',
          openrouter_provider_order: ['', ' ']
        }
      )

      expect(exacto_profile.provider_preferences).not_to include(:order)
      expect(exacto_profile.provider_preferences).to include(allow_fallbacks: true)
      expect(exacto_profile.provider_preferences).to include(sort: { by: 'latency', partition: 'none' })
      expect(auto_exacto_profile.provider_preferences).not_to include(:order)
      expect(auto_exacto_profile.provider_preferences).to include(sort: { by: 'latency', partition: 'none' })
    end
  end
end
