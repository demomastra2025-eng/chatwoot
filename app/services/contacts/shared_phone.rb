# Family numbers (owner decision 2026-09-29).
#
# A phone number is the PRIMARY number (contacts.phone_number) of at most one contact: whoever held it first. A
# separate patient card whose booking or MedElement number is already held by another contact, or was given from a chat
# without a visible phone (WhatsApp Web LID-only, Telegram Personal), gets it only as a доп. номер: the number is kept in
# custom_attributes['secondary_phones'] and the share is recorded (owner contact, how it was learnt, booking chat).
#
# Nothing in this module merges contacts or moves history. Channel lookups by phone use contacts.phone_number only; a
# доп. номер is never a lookup key. History moves only through Contacts::NumberHistoryTransferService.
module Contacts::SharedPhone # rubocop:disable Metrics/ModuleLength
  CARD_KEY = 'medelement_patient_card'.freeze
  SHARED_OWNER_KEY = 'medelement_shared_phone_owner_contact_id'.freeze
  SHARED_PHONE_KEY = 'medelement_shared_phone_number'.freeze
  SHARED_VIA_KEY = 'medelement_shared_phone_via'.freeze
  SHARED_CONVERSATION_KEY = 'medelement_shared_phone_conversation_id'.freeze
  HINT_KEY = 'medelement_shared_phone_hint'.freeze
  TRANSFERS_KEY = 'medelement_number_transfers'.freeze
  MEDELEMENT_PHONE_KEY = 'medelement_phone'.freeze
  SECONDARY_PHONES_KEY = 'secondary_phones'.freeze
  SHARE_KEYS = [SHARED_OWNER_KEY, SHARED_PHONE_KEY, SHARED_VIA_KEY, SHARED_CONVERSATION_KEY].freeze

  VIA_OWNER_PRIMARY = 'owner_primary'.freeze
  VIA_OWNER_CHAT_IDENTITY = 'owner_chat_identity'.freeze
  VIA_BOOKING_CHAT = 'booking_chat'.freeze

  PHONE_SOURCE_CHANNELS = %w[Channel::Whatsapp Channel::WhatsappWeb].freeze
  TELEGRAM_CHANNELS = %w[Channel::Telegram Channel::TelegramPersonal].freeze
  UNVERIFIED_PUBLIC_CHANNELS = %w[Channel::WebWidget Channel::Api].freeze
  # Written only by TelegramPersonal::ContactSyncService from a peer payload that carried the number.
  TELEGRAM_PEER_PHONE_KEY = 'peer_phone_number'.freeze
  WHATSAPP_WEB_PHONE_SUFFIX = '@s.whatsapp.net'.freeze

  Share = Data.define(:phone, :owner_id, :via, :conversation_id) do
    def booking_chat? = via == VIA_BOOKING_CHAT
  end

  module_function

  def digits(phone) = phone.to_s.delete('+')

  def secondary_phones(contact) = Array(contact&.custom_attributes.to_h[SECONDARY_PHONES_KEY]).compact_blank

  # The recorded share of a contact. It is effective only while its number is still one of the contact's доп. номера:
  # removing the number from secondary_phones revokes the share (routing then falls back to the appointment contact).
  def share_of(contact)
    return if contact.blank?

    attributes = contact.custom_attributes.to_h
    phone = recorded_share_phone(contact, attributes)
    return if phone.blank? || secondary_phones(contact).exclude?(phone)

    Share.new(phone: phone, owner_id: attributes[SHARED_OWNER_KEY].presence&.to_i,
              via: attributes[SHARED_VIA_KEY].presence || VIA_OWNER_PRIMARY,
              conversation_id: attributes[SHARED_CONVERSATION_KEY].presence&.to_i)
  end

  # v7 shares may record only the owner: their number is the owner's primary.
  def recorded_share_phone(contact, attributes)
    return attributes[SHARED_PHONE_KEY] if attributes[SHARED_PHONE_KEY].present?

    owner_id = attributes[SHARED_OWNER_KEY].presence
    Contact.where(account_id: contact.account_id).find_by(id: owner_id)&.phone_number if owner_id
  end

  def record_share!(attributes, phone:, owner_id:, via:, conversation_id: nil)
    via = VIA_BOOKING_CHAT if hidden_origin_kept?(attributes, phone, owner_id, via)
    attributes[SECONDARY_PHONES_KEY] = (Array(attributes[SECONDARY_PHONES_KEY]) + [phone]).compact_blank.uniq
    attributes[SHARED_OWNER_KEY] = owner_id
    attributes[SHARED_PHONE_KEY] = phone
    attributes[SHARED_VIA_KEY] = via
    attributes[SHARED_CONVERSATION_KEY] = conversation_id
    attributes[CARD_KEY] = true
    attributes
  end

  # A hidden-number share keeps its origin while the same owner only chats from the number without holding it as its
  # primary: that chat revealed the owner's own number (M2), so the share stays unresolved (M5a blocks automatic
  # promotion) until the owner holds it. Only a share first recorded as the owner's primary or chat identity is a
  # visible one.
  def hidden_origin_kept?(attributes, phone, owner_id, via)
    via == VIA_OWNER_CHAT_IDENTITY && attributes[SHARED_VIA_KEY] == VIA_BOOKING_CHAT &&
      attributes[SHARED_PHONE_KEY] == phone && attributes[SHARED_OWNER_KEY].to_i == owner_id.to_i
  end

  def clear_share!(attributes)
    SHARE_KEYS.each { |key| attributes.delete(key) }
    attributes
  end

  def primary_holder(account_id:, phone:, excluding: [])
    return if phone.blank?

    Contact.where(account_id: account_id, phone_number: phone).where.not(id: Array(excluding).compact).order(:id).first
  end

  # ContactInboxes whose channel source is exactly this number (the number's chat identities):
  # WhatsApp Cloud/360dialog and WhatsApp Web phone JIDs (digits), Twilio (E.164 or whatsapp:E.164), SMS (E.164),
  # voice inboxes (caller id, E.164 or digits), a WhatsApp Web LID provably tied to such a phone JID of the same contact
  # in the same inbox, and Telegram peers whose own payload carried the number. Email, widget and social ids never
  # identify it, and neither do API inbox source ids: a public API client chooses them freely.
  def identifying_contact_inboxes(account_id:, phone:, owner_ids: nil)
    return ContactInbox.none if phone.blank?

    ids = direct_identity_ids(account_id, phone, owner_ids)
    ids |= tied_lid_ids(ids)
    ids |= telegram_identity_ids(account_id, phone, owner_ids)
    ContactInbox.where(id: ids)
  end

  def direct_identity_ids(account_id, phone, owner_ids)
    scope = ContactInbox.joins(:inbox).where(inboxes: { account_id: account_id })
    scope = scope.where(contact_id: owner_ids) unless owner_ids.nil?
    number = digits(phone)
    scope.where(inboxes: { channel_type: PHONE_SOURCE_CHANNELS }, source_id: number)
         .or(scope.where(inboxes: { channel_type: 'Channel::TwilioSms' }, source_id: [phone, "whatsapp:#{phone}"]))
         .or(scope.where(inboxes: { channel_type: 'Channel::Sms' }, source_id: phone))
         .or(scope.where(inboxes: { channel_type: 'Channel::Voice' }, source_id: [phone, number]))
         .pluck(:id)
  end

  # A LID is tied only when a resolved payload carried both JIDs for the same contact in the same inbox: the phone JID
  # profile recorded the LID (lid_jid) or the LID profile recorded the phone JID (canonical_jid). A LID profile's
  # phone_number alone is not proof (for LID-only payloads it is copied from the contact).
  def tied_lid_ids(phone_ci_ids)
    web_cis = ContactInbox.joins(:inbox).where(id: phone_ci_ids, inboxes: { channel_type: 'Channel::WhatsappWeb' }).to_a
    return [] if web_cis.empty?

    profiles = ContactChannelProfile.where(contact_inbox_id: web_cis.map(&:id)).index_by(&:contact_inbox_id)
    web_cis.flat_map { |phone_ci| tied_lids_for(phone_ci, profiles[phone_ci.id]) }.uniq
  end

  def tied_lids_for(phone_ci, profile)
    lid = profile&.profile_data.to_h['lid_jid'].to_s
    candidates = ContactInbox.where(inbox_id: phone_ci.inbox_id, contact_id: phone_ci.contact_id).where('source_id LIKE ?', '%@lid')
    candidates.to_a.select do |lid_ci|
      next true if lid.present? && lid_ci.source_id == lid

      lid_profile = ContactChannelProfile.find_by(contact_inbox_id: lid_ci.id)
      lid_profile&.profile_data.to_h['canonical_jid'].to_s == "#{phone_ci.source_id}#{WHATSAPP_WEB_PHONE_SUFFIX}"
    end.map(&:id)
  end

  # Telegram peers are tied to a number only when the peer's own payload carried it (the payload-only marker
  # profile_data['peer_phone_number']), never through profile_data['phone_number']: ContactInboxBuilder's baseline
  # profile, the profile backfill and generic upserts copy the contact phone there. Never for the channel's own number.
  def telegram_identity_ids(account_id, phone, owner_ids)
    scope = ContactChannelProfile.joins(contact_inbox: :inbox)
                                 .where(inboxes: { account_id: account_id, channel_type: TELEGRAM_CHANNELS })
                                 .where('contact_channel_profiles.profile_data ->> ? = ?', TELEGRAM_PEER_PHONE_KEY, phone)
    scope = scope.where(contact_id: owner_ids) unless owner_ids.nil?
    scope.includes(contact_inbox: { inbox: :channel }).filter_map do |profile|
      inbox = profile.contact_inbox.inbox
      own_number = Contacts::PhoneNumberNormalizer.normalize(inbox.channel.try(:phone_number).to_s.presence)
      profile.contact_inbox_id unless own_number == phone
    end
  end

  def identity_owner_ids(account_id:, phone:, excluding: [])
    identifying_contact_inboxes(account_id: account_id, phone: phone).where.not(contact_id: Array(excluding).compact)
                                                                     .distinct.order(:contact_id).pluck(:contact_id)
  end

  # Owners of unresolved hidden-number shares for this number: a card booked from a chat that did not show its phone
  # recorded the number with that chat's contact as owner, and that contact still has no primary number. The number is
  # reserved for that owner (M2): nobody else takes it as primary automatically.
  def reservation_owner_ids(account_id:, phone:)
    return [] if phone.blank?

    owner_ids = hidden_shares(account_id: account_id, phone: phone).filter_map { |card| card.custom_attributes[SHARED_OWNER_KEY].presence&.to_i }
    return [] if owner_ids.empty?

    Contact.where(account_id: account_id, id: owner_ids.uniq).where(phone_number: [nil, '']).order(:id).pluck(:id)
  end

  # [card id, share owner id] of every effective recorded share of this number (the number is still the card's доп.
  # номер).
  def recorded_shares(account_id:, phone:)
    return [] if phone.blank?

    Contact.where(account_id: account_id).where('custom_attributes ->> ? = ?', SHARED_PHONE_KEY, phone)
           .where("custom_attributes -> 'secondary_phones' @> ?", [phone].to_json).order(:id)
           .pluck(:id, Arel.sql("custom_attributes ->> '#{SHARED_OWNER_KEY}'")).map { |card_id, owner_id| [card_id, owner_id.presence&.to_i] }
  end

  def hidden_shares(account_id:, phone:)
    Contact.where(account_id: account_id)
           .where('custom_attributes ->> ? = ?', SHARED_PHONE_KEY, phone)
           .where('custom_attributes ->> ? = ?', SHARED_VIA_KEY, VIA_BOOKING_CHAT)
           .where("custom_attributes -> 'secondary_phones' @> ?", [phone].to_json)
           .order(:id).to_a
  end

  # Whoever held the number first keeps it: a contact may take it as primary only when no other contact has it as
  # primary, no other contact chats from it, and it is not reserved for another contact's unresolved hidden share.
  def assignable_primary?(account_id:, phone:, contact_id:)
    return false if phone.blank?
    return false if primary_holder(account_id: account_id, phone: phone, excluding: [contact_id]).present?
    return false if identity_owner_ids(account_id: account_id, phone: phone, excluding: [contact_id]).any?

    reserved = reservation_owner_ids(account_id: account_id, phone: phone)
    reserved.empty? || reserved.include?(contact_id)
  end

  # Who a new card shares an unassignable number with, in priority order: the primary holder, the single contact that
  # chats from it, the owner of an unresolved hidden share (a sibling booked from the same chat). Returns nil when the
  # number is free.
  def existing_share_for(account_id:, phone:, excluding: [], preferred_owner_id: nil)
    holder = primary_holder(account_id: account_id, phone: phone, excluding: excluding)
    return { owner_id: holder.id, via: VIA_OWNER_PRIMARY } if holder

    identity_owners = identity_owner_ids(account_id: account_id, phone: phone, excluding: excluding)
    if identity_owners.any?
      owner_id = identity_owners.include?(preferred_owner_id) ? preferred_owner_id : identity_owners.first
      return { owner_id: owner_id, via: VIA_OWNER_CHAT_IDENTITY }
    end

    sibling_share(account_id, phone, excluding, preferred_owner_id)
  end

  def sibling_share(account_id, phone, excluding, preferred_owner_id)
    reserved = reservation_owner_ids(account_id: account_id, phone: phone) - Array(excluding)
    return if reserved.empty?

    owner_id = reserved.include?(preferred_owner_id) ? preferred_owner_id : reserved.first
    sibling = hidden_shares(account_id: account_id, phone: phone).find { |card| card.custom_attributes[SHARED_OWNER_KEY].to_i == owner_id }
    { owner_id: owner_id, via: VIA_BOOKING_CHAT, conversation_id: sibling&.custom_attributes&.dig(SHARED_CONVERSATION_KEY) }
  end

  # "Patient card" for every automatic merge guard: durable and identity-based, never dependent on one appointment row.
  def card?(contact)
    return false if contact.blank?
    return true if card_identity?(contact)
    return false unless contact.persisted?

    Scheduling::Appointment.exists?(patient_contact_id: contact.id) || medelement_patient_of_own_appointment?(contact)
  end

  def card_identity?(contact)
    attributes = contact.custom_attributes.to_h
    attributes[CARD_KEY] == true || attributes['medelement_patient_code'].to_s.present? ||
      [attributes['iin'], attributes['medelement_iin'], contact.identifier].any? { |value| Scheduling::IinValidator.valid?(value) }
  end

  # A patient identity that only the server writes: a card created by the booking binding, a MedElement patient (code)
  # or a contact whose provider IIN (medelement_iin) is this IIN. A self-declared identifier or custom 'iin' is not one.
  def recorded_patient_identity?(contact, iin)
    attributes = contact.custom_attributes.to_h
    attributes[CARD_KEY] == true || attributes['medelement_patient_code'].to_s.present? ||
      Scheduling::IinValidator.normalize(attributes['medelement_iin']) == iin
  end

  # A contact whose identity values only an unauthenticated public writer may have set: no server-recorded patient
  # identity, and a chat in a widget or public API inbox that was never HMAC-verified (widget PATCH, pre-chat, public API
  # create/update, lead forms). Automatic patient lookups never adopt it by IIN or demographics; staff can still link it
  # explicitly.
  def self_declared_identity?(contact, iin)
    return false if contact.blank? || !contact.persisted?
    return false if iin.present? && recorded_patient_identity?(contact, iin)
    return false if card_identity_recorded?(contact)

    ContactInbox.joins(:inbox).exists?(contact_id: contact.id, hmac_verified: false, inboxes: { channel_type: UNVERIFIED_PUBLIC_CHANNELS })
  end

  def card_identity_recorded?(contact)
    attributes = contact.custom_attributes.to_h
    attributes[CARD_KEY] == true || attributes['medelement_patient_code'].to_s.present?
  end

  def medelement_patient_of_own_appointment?(contact)
    Scheduling::Appointment.where(contact_id: contact.id, source: 'medelement')
                           .exists?(['patient_contact_id IS NULL OR patient_contact_id = ?', contact.id])
  end

  # The contact whose chat carries the card's notifications when the appointment itself has no chat (MedElement
  # imports): the card itself with its own number, else the holder of its доп. номер (when that holder is the share
  # owner or chats from the number), else the recorded share owner.
  def route_contact(card)
    return card if card.blank? || card.phone_number.present?

    share = share_of(card)
    return card if share.blank?

    holder = primary_holder(account_id: card.account_id, phone: share.phone, excluding: [card.id])
    return holder if holder && chats_as_holder?(holder, share)

    fallback_route_contact(card, share, holder)
  end

  def fallback_route_contact(card, share, holder)
    share_owner(card, share) || holder || card
  end

  def chats_as_holder?(holder, share)
    holder.id == share.owner_id ||
      identifying_contact_inboxes(account_id: holder.account_id, phone: share.phone, owner_ids: [holder.id]).exists?
  end

  def share_owner(card, share)
    Contact.where(account_id: card.account_id).find_by(id: share.owner_id) if share.owner_id
  end

  def mask(phone)
    number = digits(phone).gsub(/\D/, '')
    return if number.length < 4

    "+#{number[0]} *** ***-**-#{number.last(2)}"
  end
end
