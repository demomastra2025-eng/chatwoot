# M5(b): a hint in the card of every contact that has a number as доп. номер when that number stops being someone's
# primary ("Номер … больше не основной у A. Сделать основным для B?"), and when an automatic promotion from MedElement
# was blocked for a reason only an administrator can resolve. Nothing here promotes; the button calls
# Contacts::SharedPhonePromotionService with the confirmed preview.
module Contacts::SharedPhoneHint
  HINT_KEY = Contacts::SharedPhone::HINT_KEY
  HINTABLE_BLOCKS = %i[siblings multiple_previous_holders previous_holder_is_card unproven_lid_chat owner_missing].freeze

  module_function

  # Contacts with the number as доп. номер that were given it as a family number (a recorded share of that number) or
  # are patient cards; a number that is someone's primary again, or reserved for an unresolved hidden share, gets none.
  def candidates(account_id:, phone:, excluding: [])
    return [] if phone.blank? || Contacts::SharedPhone.primary_holder(account_id: account_id, phone: phone).present?
    return [] if Contacts::SharedPhone.reservation_owner_ids(account_id: account_id, phone: phone).any?

    Contact.where(account_id: account_id).where("custom_attributes -> 'secondary_phones' @> ?", [phone].to_json)
           .where.not(id: Array(excluding).compact).where(phone_number: [nil, '']).order(:id).to_a
           .select { |contact| Contacts::SharedPhone.share_of(contact)&.phone == phone || Contacts::SharedPhone.card?(contact) }
  end

  def create_for_release!(account_id:, phone:, previous_holder_id:)
    flag_card_number_chats(account_id, phone, previous_holder_id)
    contacts = candidates(account_id: account_id, phone: phone, excluding: [previous_holder_id])
    contacts.each do |contact|
      write!(contact, phone: phone, previous_holder_id: previous_holder_id, reason: 'released', candidate_ids: contacts.map(&:id))
    end
    contacts.size
  end

  # A card that released the number (staff changed its phone) may still own chats whose channel source is that number,
  # e.g. the chat its own reminders opened. They are no proof that the card owns the number any more (M7x only trusts a
  # card holding the number as primary) and nothing moves them automatically (M6); they are logged here (ids and counts
  # only) and counted by the dry-run report (cards_with_chats_of_other_number).
  def flag_card_number_chats(account_id, phone, previous_holder_id)
    previous = Contact.find_by(id: previous_holder_id, account_id: account_id)
    return if previous.blank? || !Contacts::SharedPhone.card?(previous)

    count = Contacts::SharedPhone.identifying_contact_inboxes(account_id: account_id, phone: phone, owner_ids: [previous.id]).count
    return if count.zero?

    Rails.logger.warn({ event: 'shared_phone_released_card_keeps_number_chats', account_id: account_id, contact_id: previous.id,
                        contact_inboxes: count }.to_json)
  end

  def ensure_for_blocked_promotion!(card, decision)
    return unless hintable?(card, decision)

    contacts = candidates(account_id: card.account_id, phone: decision.phone)
    return if contacts.none? { |contact| contact.id == card.id }

    write!(card, phone: decision.phone, previous_holder_id: Contacts::SharedPhone.share_of(card)&.owner_id, reason: 'medelement',
                 candidate_ids: contacts.map(&:id))
  end

  def hintable?(card, decision)
    decision.reason.in?(HINTABLE_BLOCKS) && decision.phone.present? && current(card).blank?
  end

  def write!(contact, phone:, previous_holder_id:, reason:, candidate_ids:)
    attributes = contact.reload.custom_attributes.to_h
    attributes[HINT_KEY] = { 'phone' => phone, 'previous_holder_contact_id' => previous_holder_id, 'reason' => reason,
                             'detected_at' => Time.current.iso8601, 'candidate_contact_ids' => candidate_ids, 'dismissed_at' => nil }
    contact.update_columns(custom_attributes: attributes, updated_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
    contact.dispatch_shared_phone_update_event
  end

  # The hint is re-validated live: once the number is someone's primary again or left the contact's доп. номера it is
  # dropped. A dismissed hint is kept (the report counts it) but not shown.
  def current(contact)
    hint = contact.custom_attributes.to_h[HINT_KEY]
    return if hint.blank?
    return hint unless stale?(contact, hint['phone'])

    clear!(contact)
    nil
  end

  def stale?(contact, phone)
    contact.phone_number.present? || Contacts::SharedPhone.secondary_phones(contact).exclude?(phone) ||
      Contacts::SharedPhone.primary_holder(account_id: contact.account_id, phone: phone).present?
  end

  def visible(contact)
    hint = current(contact)
    hint if hint.present? && hint['dismissed_at'].blank?
  end

  def dismiss!(contact)
    hint = current(contact)
    return false if hint.blank?

    attributes = contact.custom_attributes.to_h
    attributes[HINT_KEY] = hint.merge('dismissed_at' => Time.current.iso8601)
    contact.update_columns(custom_attributes: attributes, updated_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
  end

  def clear!(contact)
    attributes = contact.custom_attributes.to_h
    return true unless attributes.key?(HINT_KEY)

    contact.update_columns(custom_attributes: attributes.except(HINT_KEY), updated_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
  end
end
