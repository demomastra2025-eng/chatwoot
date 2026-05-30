# frozen_string_literal: true

class Llm::ProviderVisibilityPolicy
  NORMAL_CAPTAIN_PROVIDER = 'openrouter'
  VOICE_PROVIDER = 'gemini'
  DIRECT_PROVIDER_DISABLED_REASON = 'direct_provider_disabled'
  VOICE_ONLY_PROVIDER_REASON = 'voice_only_provider'
  NORMAL_CAPTAIN_SURFACES = %w[captain_settings normal_captain captain_preferences].freeze
  VOICE_SURFACES = %w[voice ai_voice telephony_ai_voice realtime_voice].freeze

  class << self
    def visible_providers(surface: :captain_settings)
      Llm::Models.providers.to_h.select do |provider_name, _provider_config|
        visible_provider?(provider_name, surface: surface)
      end
    end

    def visible_provider?(provider_name, surface: :captain_settings)
      provider = provider_name.to_s
      surface_name = surface.to_s

      return provider == NORMAL_CAPTAIN_PROVIDER if NORMAL_CAPTAIN_SURFACES.include?(surface_name)
      return provider == VOICE_PROVIDER if VOICE_SURFACES.include?(surface_name)

      true
    end

    def normal_captain_provider?(provider_name)
      provider_name.to_s == NORMAL_CAPTAIN_PROVIDER
    end

    def voice_provider?(provider_name)
      provider_name.to_s == VOICE_PROVIDER
    end

    def hidden_reason(provider_name, surface: :captain_settings)
      return if visible_provider?(provider_name, surface: surface)
      return VOICE_ONLY_PROVIDER_REASON if voice_provider?(provider_name)

      DIRECT_PROVIDER_DISABLED_REASON
    end

    def metadata_for(provider_name, surface: :captain_settings)
      {
        visible: visible_provider?(provider_name, surface: surface),
        hidden_reason: hidden_reason(provider_name, surface: surface)
      }
    end
  end
end
