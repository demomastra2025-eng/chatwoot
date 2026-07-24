module Webhooks::WhatsappLegacyVerificationHelpers
  def verification_context_for(channel, payload, verification_context)
    return verification_context unless legacy_signed_context?(verification_context)

    Rails.logger.warn('[WHATSAPP_WEBHOOK] processing legacy signed job with runtime-bound routing context')
    legacy_signed_verification_context(channel, payload)
  end

  def legacy_signed_context?(verification_context)
    verification_context[:hmac_verified] == true && verification_context.keys.map(&:to_s) == ['hmac_verified']
  end

  def legacy_signed_verification_context(channel, payload)
    route_phone = payload[:phone_number]
    waba_scoped = route_phone.blank?
    waba_ids = Array(payload[:entry]).filter_map { |entry| entry[:id] }.map(&:to_s).uniq
    {
      hmac_verified: true,
      legacy_signed: true,
      channel_id: waba_scoped ? nil : channel&.id,
      channel_identity: waba_scoped ? {} : Whatsapp::AuthenticatedWebhookRoute.identity_snapshot(channel, route_phone),
      waba_account_ids: waba_ids.index_with { |waba_id| Channel::Whatsapp.unambiguous_waba_owner_account_id(waba_id) },
      waba_scoped: waba_scoped
    }.with_indifferent_access
  end
end
