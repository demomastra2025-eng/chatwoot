class Whatsapp::ContactIdentityResolver
  include RegexHelper

  WHATSAPP_PREFIX = 'whatsapp:'.freeze
  PROVIDER_BSUID_KEYS = %i[user_id parent_user_id].freeze

  pattr_initialize [:inbox!, :message!, :contact_params, { outgoing_echo: false }]

  def perform
    return if source_id.blank?

    contact_inbox = ::ContactInboxWithContactBuilder.new(
      source_id: source_id,
      inbox: inbox,
      contact_attributes: contact_attributes
    ).perform

    backfill_contact_phone!(contact_inbox.contact)
    contact_inbox
  end

  def source_id
    @source_id ||= source_id_from_provider_contact || source_id_from_message_phone
  end

  def contact_phone_number
    @contact_phone_number ||= self.class.phone_number_for(message_phone_identifier)
  end

  def self.normalize_source_id(identifier)
    value = identifier.to_s.strip
    return if value.blank?

    value = value.delete_prefix(WHATSAPP_PREFIX)
    value = value.delete_prefix('+')
    return unless WHATSAPP_CHANNEL_REGEX.match?(value)

    value
  end

  def self.phone_number_for(identifier)
    source_id = normalize_source_id(identifier)
    return if source_id.blank?

    "+#{source_id}"
  end

  private

  def contact_attributes
    {
      name: contact_name,
      phone_number: contact_phone_number
    }.compact
  end

  def contact_name
    contact_params&.dig(:profile, :name).presence || contact_phone_number
  end

  def source_id_from_provider_contact
    provider_bsuid_candidates.filter_map do |candidate|
      provider_bsuid(candidate)
    end.first
  end

  def source_id_from_message_phone
    normalized_source_id = self.class.normalize_source_id(message_phone_identifier)
    return if normalized_source_id.blank?

    processed_source_id(normalized_source_id)
  end

  def processed_source_id(normalized_source_id)
    Whatsapp::PhoneNumberNormalizationService.new(inbox).normalize_and_find_contact_by_provider(normalized_source_id, :cloud)
  end

  def provider_bsuid_candidates
    explicit_bsuid_candidates = PROVIDER_BSUID_KEYS.map { |key| contact_params&.[](key) }
    wa_id = contact_params&.[](:wa_id)

    explicit_bsuid_candidates + [wa_id].reject { |candidate| same_as_message_phone?(candidate) }
  end

  def provider_bsuid(candidate)
    value = candidate.to_s.strip
    return if value.blank? || same_as_message_phone?(value)
    return unless WHATSAPP_CHANNEL_REGEX.match?(value)

    value
  end

  def same_as_message_phone?(candidate)
    self.class.normalize_source_id(candidate) == self.class.normalize_source_id(message_phone_identifier)
  end

  def message_phone_identifier
    outgoing_echo ? message[:to] : message[:from]
  end

  def backfill_contact_phone!(contact)
    return if contact.blank? || contact_phone_number.blank? || contact.phone_number.present?

    contact.update!(phone_number: contact_phone_number)
  rescue ActiveRecord::RecordInvalid => e
    Rails.logger.warn("[WhatsApp] Could not backfill contact phone number for contact=#{contact.id}: #{e.message}")
  end
end
