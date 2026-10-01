# M5(a): when a MedElement sync of a card confirms that the card's доп. номер is the patient's own number, it becomes
# the card's primary automatically, but only when nothing else could still claim it. Every blocking reason leaves the
# number as доп. номер (the administrator can promote it from the hint, M5(b)).
module Contacts::SharedPhonePromotionPolicy
  CONFIG_KEY = Contacts::SharedPhoneSwitches::AUTO_PROMOTION
  Decision = Data.define(:status, :reason, :phone, :previous_holder) do
    def promote? = status == :promote
  end

  module_function

  # Switch ONELINK_SHARED_PHONE_AUTO_PROMOTION (Contacts::SharedPhoneSwitches), default off. The account argument is
  # kept for the callers; the switch is installation wide.
  def auto_enabled?(_account = nil) = Contacts::SharedPhoneSwitches.auto_promotion?

  # Cheap pre-check used by the MedElement resolver before enqueueing the job.
  def auto_candidate?(card)
    return false if card.blank? || card.phone_number.present? || !auto_enabled?

    share = Contacts::SharedPhone.share_of(card)
    share.present? && card.custom_attributes.to_h[Contacts::SharedPhone::MEDELEMENT_PHONE_KEY] == share.phone &&
      !reverted_transfer?(card, share.phone) &&
      Contacts::SharedPhone.primary_holder(account_id: card.account_id, phone: share.phone, excluding: [card.id]).blank?
  end

  # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
  # check_switches: false evaluates the policy as if the switches were on (the dry-run report).
  def auto_decision(card, check_switches: true)
    return blocked(:kill_switch) if check_switches && !auto_enabled?
    return blocked(:not_a_card) unless Contacts::SharedPhone.card?(card)
    return blocked(:has_primary) if card.phone_number.present?

    share = Contacts::SharedPhone.share_of(card)
    return blocked(:no_share) if share.blank?

    phone = share.phone
    return blocked(:reverted_transfer, phone) if reverted_transfer?(card, phone)

    medelement_phone = card.custom_attributes.to_h[Contacts::SharedPhone::MEDELEMENT_PHONE_KEY]
    # nil: not synced since the snapshot existed; '': synced, MedElement has no phone for the patient.
    return blocked(:unknown_medelement_phone, phone) if medelement_phone.nil?
    return blocked(:no_medelement_phone, phone) if medelement_phone.blank?
    return blocked(:medelement_phone_mismatch, phone) if medelement_phone != phone
    return blocked(:held_by_other, phone) if Contacts::SharedPhone.primary_holder(account_id: card.account_id, phone: phone, excluding: [card.id])

    owner = Contact.find_by(id: share.owner_id, account_id: card.account_id) if share.owner_id
    return blocked(:owner_missing, phone) if owner.blank?
    # A hidden-number share (the number was given in a chat that did not show its phone) whose owner still has no
    # primary is unresolved (M5a): that chat may still reveal the number as the owner's own (M2), so only the
    # administrator can decide. The origin sticks when the owner's chat later shows the number without the owner taking
    # it (Contacts::SharedPhone.hidden_origin_kept?). The owner of a visible share (it held the number as primary or
    # chatted from it when the share was recorded) that gave up its primary is not unresolved.
    return blocked(:owner_unresolved, phone) if share.booking_chat? && owner.phone_number.blank?

    holders = Contacts::SharedPhone.identity_owner_ids(account_id: card.account_id, phone: phone, excluding: [card.id])
    return blocked(:multiple_previous_holders, phone) if holders.size > 1

    previous = Contact.find_by(id: holders.first, account_id: card.account_id) if holders.any?
    return blocked(:siblings, phone) if sibling_ids(card, phone, [owner.id, previous&.id]).any?
    return blocked(:previous_holder_is_card, phone) if previous && Contacts::SharedPhone.card?(previous)
    # A previous holder owns the number's chats: promoting without moving them would leave the card's own number filed
    # under another contact, so the promotion waits for ONELINK_SHARED_PHONE_HISTORY_TRANSFER.
    return blocked(:history_transfer_disabled, phone) if previous && check_switches && !Contacts::SharedPhoneSwitches.history_transfer?

    preview = Contacts::NumberHistoryTransferPreview.new(account: card.account, phone: phone, card: card, previous_holder: previous)
    return blocked(:unproven_lid_chat, phone) if preview.unproven_lid_contact_inboxes.any?
    return blocked(:write_in_flight, phone) if Contacts::PatientIdentityMergeGuard.patient_binding_write_in_flight?(card)

    Decision.new(status: :promote, reason: nil, phone: phone, previous_holder: previous)
  end
  # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity

  # An administrator reverted a transfer of this number to this card (rake onelink:shared_phones:revert_transfer): the
  # routine MedElement sync must not promote it again. Only the administrator can (hint button, M5b).
  def reverted_transfer?(card, phone)
    Array(card.custom_attributes.to_h[Contacts::SharedPhone::TRANSFERS_KEY]).any? do |entry|
      entry['phone'] == phone && (entry['reverted_at'].present? || entry['revert_of'].present?)
    end
  end

  def sibling_ids(card, phone, excluded)
    Contact.where(account_id: card.account_id).where("custom_attributes -> 'secondary_phones' @> ?", [phone].to_json)
           .where.not(id: [card.id, *excluded].compact).pluck(:id)
  end

  def blocked(reason, phone = nil) = Decision.new(status: :blocked, reason: reason, phone: phone, previous_holder: nil)
end
