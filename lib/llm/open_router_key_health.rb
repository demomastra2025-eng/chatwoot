# frozen_string_literal: true

class Llm::OpenRouterKeyHealth
  CACHE_KEY = 'llm/openrouter/key_health'
  MANAGEMENT_API_KEY_CONFIG = 'CAPTAIN_OPENROUTER_MANAGEMENT_API_KEY'
  PROVIDER = Llm::OpenRouterModelCatalog::PROVIDER

  class << self
    def refresh!
      key_source = key_source_metadata
      payload = if key_source[:api_key].blank?
                  missing_key_payload(key_source)
                else
                  fetch_health_payload(key_source)
                end

      Rails.cache.write(CACHE_KEY, payload)
      payload
    end

    def metadata
      Rails.cache.read(CACHE_KEY) || {
        status: configured? ? 'not_checked' : 'missing',
        configured: configured?,
        checked_at: nil
      }
    end

    def configured?
      key_source_metadata[:api_key].present?
    end

    private

    def fetch_health_payload(key_source)
      key = Llm::OpenRouterKeyClient.current_key(
        api_key: key_source[:api_key],
        api_base: key_source[:api_base]
      )
      credits = key.management_capable? ? fetch_credits(key_source) : skipped_credits_payload(key)
      {
        status: health_status(key, credits),
        configured: true,
        checked_at: Time.current.iso8601,
        source: key_source[:source],
        key: key.to_h,
        credits: credits
      }
    rescue StandardError => e
      error_payload(key_source, e)
    end

    def fetch_credits(key_source)
      Llm::OpenRouterKeyClient.credits(
        api_key: key_source[:api_key],
        api_base: key_source[:api_base]
      ).to_h.merge(status: 'available')
    rescue StandardError => e
      {
        status: 'unavailable',
        error: "#{e.class}: #{Llm::ObservabilityPayload.sanitize_error_message(e)}"
      }
    end

    def skipped_credits_payload(key)
      {
        status: 'management_key_required',
        reason: "credits endpoint requires a management key; current key type is #{key.key_type}"
      }
    end

    def health_status(key, credits)
      return 'expired' if expired?(key.expires_at)
      return 'key_limit_exhausted' if key.limit_remaining.present? && key.limit_remaining <= 0
      return 'credits_exhausted' if credits[:remaining_credits].present? && credits[:remaining_credits] <= 0
      return 'credits_unavailable' if credits[:status] == 'unavailable'

      'valid'
    end

    def expired?(expires_at)
      return false if expires_at.blank?

      Time.iso8601(expires_at).past?
    rescue ArgumentError
      false
    end

    def error_payload(key_source, error)
      classification = Llm::OpenRouterErrorClassifier.classify(error)
      {
        status: error_status(classification),
        configured: true,
        checked_at: Time.current.iso8601,
        source: key_source[:source],
        error_class: error.class.name,
        error: Llm::ObservabilityPayload.sanitize_error_message(error),
        openrouter_error_category: classification.category,
        retryable: classification.retryable
      }.compact
    end

    def error_status(classification)
      return 'invalid' if classification.category == 'invalid_api_key'
      return 'credits_exhausted' if classification.category == 'insufficient_credits'

      'unavailable'
    end

    def missing_key_payload(key_source)
      {
        status: 'missing',
        configured: false,
        checked_at: Time.current.iso8601,
        source: key_source[:source]
      }
    end

    def key_source_metadata
      management_key = installation_config(MANAGEMENT_API_KEY_CONFIG)
      {
        api_key: management_key.presence || Llm::Config.api_key(PROVIDER),
        api_base: Llm::Config.api_base(PROVIDER),
        source: management_key.present? ? 'management_key' : 'runtime_key'
      }
    end

    def installation_config(name)
      InstallationConfig.find_by(name: name)&.value.presence
    rescue StandardError
      nil
    end
  end
end
