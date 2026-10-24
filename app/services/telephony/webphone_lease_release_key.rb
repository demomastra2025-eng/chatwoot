# A signed key the browser tab that holds a SIP line lease gets with its token.
# The tab sends it back when it closes or is signed out (navigator.sendBeacon
# carries no auth headers, and a sign-in elsewhere has already revoked the
# session), so the line is released at once instead of after the lease TTL.
# The key releases only that lease: it names the registration instance, which
# changes with every new lease.
class Telephony::WebphoneLeaseReleaseKey
  PARAM = :release_key
  PURPOSE = :telephony_webphone_lease_release
  TTL = 7.days

  Release = Data.define(:account_id, :sip_profile_id, :registration_instance_id)

  def self.generate(profile:, registration_instance_id:)
    return if profile.blank? || registration_instance_id.blank?

    verifier.generate(
      { account_id: profile.account_id, sip_profile_id: profile.id, registration_instance_id: registration_instance_id.to_s },
      purpose: PURPOSE,
      expires_in: TTL
    )
  end

  def self.resolve(key)
    return if key.blank?

    payload = verifier.verified(key.to_s, purpose: PURPOSE)
    return unless payload.is_a?(Hash)

    payload = payload.with_indifferent_access
    return if payload.values_at(:account_id, :sip_profile_id, :registration_instance_id).any?(&:blank?)

    Release.new(
      account_id: payload[:account_id].to_i,
      sip_profile_id: payload[:sip_profile_id].to_i,
      registration_instance_id: payload[:registration_instance_id].to_s
    )
  rescue ActiveSupport::MessageVerifier::InvalidSignature, ArgumentError
    nil
  end

  def self.verifier
    Rails.application.message_verifier(PURPOSE)
  end

  private_class_method :verifier
end
