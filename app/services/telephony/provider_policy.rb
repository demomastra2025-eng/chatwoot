# frozen_string_literal: true

# Runtime isolation for providers whose credentials must not be shared by DEV and PROD.
class Telephony::ProviderPolicy
  DISABLED_CODE = 'TELEPHONY_PROVIDER_DISABLED'

  class << self
    def enabled?(provider)
      return true unless provider.to_s.strip.downcase == 'beeline'

      ENV.fetch('TELEPHONY_BEELINE_ENABLED', 'true').to_s.strip.downcase.in?(%w[true 1 yes on])
    end

    def enabled_for_profile?(profile)
      return false if profile.blank?
      return true if enabled?('beeline')

      enabled?(provider_for_profile(profile))
    end

    def provider_for_profile(profile)
      identity = Telephony::OperatorIdentityResolver::Identity.new(source: :sip_profile, record: profile)
      return identity.provider if identity.provider.present?

      binding = profile&.inbox&.telephony_number_binding
      binding&.provider.presence || binding&.provider_connection&.provider_kind
    end

    def ensure_enabled!(provider)
      return if enabled?(provider)

      raise_disabled!
    end

    def ensure_enabled_for_profile!(profile)
      return if enabled_for_profile?(profile)

      raise_disabled!
    end

    def ensure_enabled_for_inbox!(inbox)
      return if enabled?('beeline')

      ensure_enabled!(inbox&.channel&.try(:provider))
    end

    private

    def raise_disabled!
      raise Telephony::Error.new(code: DISABLED_CODE, message: 'Voice provider is unavailable',
                                 status: :forbidden)
    end
  end
end
