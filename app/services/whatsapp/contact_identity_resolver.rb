class Whatsapp::ContactIdentityResolver
  WHATSAPP_PREFIX = 'whatsapp:'.freeze
  PROVIDER_BSUID_KEYS = %i[user_id parent_user_id].freeze
  INCOMING_MESSAGE_BSUID_KEYS = %i[from_user_id from_parent_user_id].freeze
  OUTGOING_MESSAGE_BSUID_KEYS = %i[to_user_id to_parent_user_id].freeze

  pattr_initialize [:inbox!, :message!, :contact_params, { outgoing_echo: false }]

  def perform
    return if source_ids.blank?

    contact_inbox = find_or_create_contact_inbox
    sync_contact_identifiers(contact_inbox)
    contact_inbox
  end

  def source_id
    source_ids.first
  end

  def source_ids
    @source_ids ||= ([phone_source_id] + bsuid_source_ids).compact_blank.uniq
  end

  def contact_phone_number
    @contact_phone_number ||= self.class.phone_number_for(phone_source_id)
  end

  def self.normalize_source_id(identifier)
    phone_source_id(identifier) || bsuid_source_id(identifier)
  end

  def self.phone_source_id(identifier)
    value = normalized_identifier(identifier)
    return if value.blank?
    return unless value.match?(/\A\d{1,15}\z/)

    value
  end

  def self.bsuid_source_id(identifier)
    value = normalized_identifier(identifier)
    return if value.blank?
    return unless RegexHelper::WHATSAPP_BSUID_REGEX.match?(value)

    value
  end

  def self.phone_number_for(identifier)
    source_id = phone_source_id(identifier)
    return if source_id.blank?

    "+#{source_id}"
  end

  def self.normalized_identifier(identifier)
    value = identifier.to_s.strip
    return if value.blank?

    value.delete_prefix(WHATSAPP_PREFIX).delete_prefix('+')
  end

  private_class_method :normalized_identifier

  private

  def find_or_create_contact_inbox
    ContactInboxSourceIdResolver.new(
      inbox: inbox,
      source_ids: source_ids,
      contact_attributes: contact_attributes
    ).perform
  end

  def sync_contact_identifiers(contact_inbox)
    Whatsapp::IdentifierSyncService.new(
      contact_inbox: contact_inbox,
      contact: contact_inbox.contact
    ).perform(
      source_ids: source_ids,
      username: contact_params&.dig(:profile, :username),
      phone_number: contact_phone_number
    )
  end

  def contact_attributes
    {
      name: contact_name,
      phone_number: contact_phone_number
    }.compact
  end

  def contact_name
    contact_params&.dig(:profile, :name).presence || contact_phone_number || source_ids.first
  end

  def bsuid_source_ids
    @bsuid_source_ids ||= explicit_bsuid_candidates.filter_map do |candidate|
      self.class.bsuid_source_id(candidate)
    end.uniq
  end

  def explicit_bsuid_candidates
    provider_bsuid_candidates + message_bsuid_candidates
  end

  def provider_bsuid_candidates
    PROVIDER_BSUID_KEYS.map { |key| contact_params&.[](key) }
  end

  def message_bsuid_candidates
    message_bsuid_keys.map { |key| message[key] }
  end

  def message_bsuid_keys
    outgoing_echo ? OUTGOING_MESSAGE_BSUID_KEYS : INCOMING_MESSAGE_BSUID_KEYS
  end

  def phone_source_id
    @phone_source_id ||= begin
      raw_phone_source_id = phone_identifiers.filter_map { |identifier| self.class.phone_source_id(identifier) }.first
      raw_phone_source_id.present? ? processed_source_id(raw_phone_source_id) : nil
    end
  end

  def phone_identifiers
    if outgoing_echo
      [message[:to]]
    else
      [message[:from], contact_params&.[](:wa_id)]
    end
  end

  def processed_source_id(normalized_source_id)
    Whatsapp::PhoneNumberNormalizationService.new(inbox).normalize_and_find_contact_by_provider(normalized_source_id, :cloud)
  end
end
