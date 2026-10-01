# M9 dry-run report: how many cards WOULD be auto-promoted / have history transferred, and why others are blocked.
# Read-only; counts only, never names, numbers, IINs or codes. Evaluates the policy as if the switches
# (Contacts::SharedPhoneSwitches) were on so the counts can be checked on PROD before enabling them.
#
# Release-1 patients have no recorded share and no MedElement phone snapshot yet: their next sync records them (with
# the switches off it records only, nothing is promoted). Until every linked patient was synced once, report_complete
# is false and patients_pending_first_sync says how many are still unknown; unrecorded_chat_identity_patients estimates,
# from the numbers already stored, how many of them will get a share from a number another contact chats from.
class Contacts::SharedPhoneReport
  SHARE_VIAS = [
    Contacts::SharedPhone::VIA_OWNER_PRIMARY, Contacts::SharedPhone::VIA_OWNER_CHAT_IDENTITY, Contacts::SharedPhone::VIA_BOOKING_CHAT
  ].freeze
  # Printed even when zero, so an empty account reads as "nothing would happen", not as a missing count.
  ALWAYS_REPORTED = %w[
    cards_with_shared_phone would_auto_promote would_transfer_contact_inboxes would_transfer_conversations would_transfer_messages
    patients_pending_first_sync unrecorded_chat_identity_patients open_hints dismissed_hints cards_with_chats_of_other_number
  ].freeze
  NUMBER_IDENTITY_CHANNELS = %w[Channel::Whatsapp Channel::WhatsappWeb Channel::TwilioSms Channel::Sms Channel::Voice].freeze
  CARD_CONDITION = "(contacts.custom_attributes ->> '#{Contacts::SharedPhone::CARD_KEY}' = 'true' OR " \
                   "COALESCE(contacts.custom_attributes ->> 'medelement_patient_code', '') <> '')".freeze

  def initialize(account:)
    @account = account
  end

  def counts
    counts = base_counts
    shared_cards.find_each { |card| count_card(counts, card) }
    unrecorded_patients.find_each { |patient| count_unrecorded_patient(counts, patient) }
    count_hints(counts)
    counts['legacy_card_primary_is_other_chat_identity'] = legacy_card_primary_count
    counts['cards_with_chats_of_other_number'] = cards_with_chats_of_other_number
    counts['report_complete'] = counts['patients_pending_first_sync'].zero? && counts['blocked_unknown_medelement_phone'].zero?
    counts
  end

  private

  def base_counts
    counts = Hash.new(0).merge(ALWAYS_REPORTED.index_with(0))
    counts.merge('account_id' => @account.id, 'auto_promotion_enabled' => Contacts::SharedPhoneSwitches.auto_promotion?,
                 'manual_promotion_enabled' => Contacts::SharedPhoneSwitches.manual_promotion?,
                 'history_transfer_enabled' => Contacts::SharedPhoneSwitches.history_transfer?)
  end

  def shared_cards
    @account.contacts.where("custom_attributes ->> '#{Contacts::SharedPhone::SHARED_PHONE_KEY}' IS NOT NULL")
  end

  def count_card(counts, card)
    share = Contacts::SharedPhone.share_of(card)
    return if share.blank?

    counts['cards_with_shared_phone'] += 1
    counts["shares_#{share.via}"] += 1 if SHARE_VIAS.include?(share.via)
    counts['hidden_unresolved'] += 1 if hidden_unresolved?(share)
    counts['holder_present'] += 1 if Contacts::SharedPhone.primary_holder(account_id: @account.id, phone: share.phone, excluding: [card.id])
    count_decision(counts, card)
  end

  # Linked MedElement patients without a primary number and without a recorded share.
  def unrecorded_patients
    @account.contacts.where(phone_number: [nil, ''])
            .where("COALESCE(custom_attributes ->> 'medelement_patient_code', '') <> ''")
            .where("custom_attributes ->> '#{Contacts::SharedPhone::SHARED_PHONE_KEY}' IS NULL")
  end

  # The snapshot key is written by every sync ('' when MedElement has no phone): only a missing key is pending.
  def count_unrecorded_patient(counts, patient)
    attributes = patient.custom_attributes.to_h
    counts['patients_pending_first_sync'] += 1 unless attributes.key?(Contacts::SharedPhone::MEDELEMENT_PHONE_KEY)
    numbers = ([attributes[Contacts::SharedPhone::MEDELEMENT_PHONE_KEY]] + Contacts::SharedPhone.secondary_phones(patient)).compact_blank.uniq
    counts['unrecorded_chat_identity_patients'] += 1 if numbers.any? { |phone| free_chat_identity?(patient, phone) }
  end

  # Nobody holds the number as primary but another contact chats from it: the next sync records the share with that
  # contact, and the number can then be promoted with its chat history (a).
  def free_chat_identity?(patient, phone)
    Contacts::SharedPhone.primary_holder(account_id: @account.id, phone: phone, excluding: [patient.id]).blank? &&
      Contacts::SharedPhone.identity_owner_ids(account_id: @account.id, phone: phone, excluding: [patient.id]).any?
  end

  def hidden_unresolved?(share)
    return false unless share.booking_chat? && share.owner_id

    @account.contacts.exists?(id: share.owner_id, phone_number: [nil, ''])
  end

  def count_decision(counts, card)
    decision = Contacts::SharedPhonePromotionPolicy.auto_decision(card, check_switches: false)
    return counts["blocked_#{decision.reason}"] += 1 unless decision.promote?

    counts['would_auto_promote'] += 1
    preview = Contacts::NumberHistoryTransferPreview.new(account: @account, phone: decision.phone, card: card,
                                                         previous_holder: decision.previous_holder)
    counts['would_transfer_contact_inboxes'] += preview.moving_contact_inboxes.size
    counts['would_transfer_conversations'] += preview.conversations.size
    counts['would_transfer_messages'] += preview.message_counts.values.sum
  end

  def count_hints(counts)
    @account.contacts.where("custom_attributes ->> '#{Contacts::SharedPhone::HINT_KEY}' IS NOT NULL").find_each do |contact|
      hint = contact.custom_attributes[Contacts::SharedPhone::HINT_KEY].to_h
      counts[hint['dismissed_at'].present? ? 'dismissed_hints' : 'open_hints'] += 1
    end
  end

  # Cards that still own a chat whose channel source is a number other than their primary (typically the own-route chat
  # of a number the card released when staff changed its phone). Such chats keep filing that number's messages under the
  # card and are no proof that the card owns the number; history moves only through an explicit transfer.
  def cards_with_chats_of_other_number
    ContactInbox.joins(:inbox, :contact)
                .where(inboxes: { account_id: @account.id, channel_type: NUMBER_IDENTITY_CHANNELS })
                .where(CARD_CONDITION)
                .where("contact_inboxes.source_id NOT LIKE '%@lid'")
                .where("regexp_replace(contact_inboxes.source_id, '[^0-9]', '', 'g') <> " \
                       "regexp_replace(COALESCE(contacts.phone_number, ''), '[^0-9]', '', 'g')")
                .distinct.count(:contact_id)
  end

  # v7 data: a card whose own primary is another contact's chat identity (it took the family number as its own).
  def legacy_card_primary_count
    @account.contacts.where("custom_attributes ->> '#{Contacts::SharedPhone::CARD_KEY}' = 'true'").where.not(phone_number: [nil, ''])
            .find_each.count do |card|
      Contacts::SharedPhone.identity_owner_ids(account_id: @account.id, phone: card.phone_number, excluding: [card.id]).any?
    end
  end
end
