# JSON for the contact card (M4 option A + M5 b): where this card's notifications go, the promotion hint and, when a
# hint is shown, exactly what the promotion would move. Masked numbers only; the raw number is never echoed. While
# ONELINK_SHARED_PHONE_MANUAL_PROMOTION is off (the default) neither the hint nor the preview is returned, so the card
# shows no hint, button or dialog.
class Contacts::SharedPhonePresenter
  def initialize(contact:)
    @contact = contact
  end

  def as_json(*)
    manual_promotion = Contacts::SharedPhoneSwitches.manual_promotion?
    hint = Contacts::SharedPhoneHint.visible(@contact) if manual_promotion
    {
      patient_card: Contacts::SharedPhone.card?(@contact),
      own_conversations_count: Conversation.where(account_id: @contact.account_id, contact_id: @contact.id).count,
      route: route_json,
      manual_promotion_enabled: manual_promotion,
      hint: hint_json(hint),
      promotion_preview: (preview_json(hint['phone']) if hint)
    }
  end

  private

  def route_json
    route = current_route
    return { kind: 'unroutable', masked_phone: Contacts::SharedPhone.mask(route_phone(route)) } if route&.unroutable?
    return { kind: 'none' } if route&.contact.blank?

    {
      kind: route.kind.to_s, contact: { id: route.contact.id, name: route.contact.name },
      masked_phone: Contacts::SharedPhone.mask(route_phone(route)),
      conversation_display_id: route.conversation&.display_id, inbox_name: route.conversation&.inbox&.name
    }
  end

  def route_phone(route) = route.kind == :own ? @contact.phone_number : Contacts::SharedPhone.share_of(@contact)&.phone

  # The next open appointment of this card decides the route (the latest one when none is upcoming); a card without
  # appointments shows where its доп. номер would be routed.
  def current_route
    appointment = upcoming_appointment
    return Reminders::PatientSubjectGuard.notification_route(appointment) if appointment
    return Reminders::PatientSubjectGuard::Route.new(contact: @contact, conversation: nil, kind: :own) if @contact.phone_number.present?

    share_route
  end

  def upcoming_appointment
    scope = Scheduling::Appointment.where(account_id: @contact.account_id, patient_contact_id: @contact.id).where.not(status: 'cancelled')
    scope.where('starts_at >= ?', Time.current).order(:starts_at).first || scope.order(starts_at: :desc).first
  end

  # A card without appointments: its доп. номер goes through the holder's chat on the number (linked only when that
  # chat's channel identity is the number), or for a hidden-number share through the chat where the number was given
  # (linked only while it is still the share owner's). Never "the latest chat" of either (sc8rv1 round 3 H2c).
  def share_route
    share = Contacts::SharedPhone.share_of(@contact)
    return if share.blank?

    holder = Contacts::SharedPhone.primary_holder(account_id: @contact.account_id, phone: share.phone, excluding: [@contact.id])
    return route(holder, Reminders::PatientSubjectGuard.holder_phone_conversation(holder, share.phone), :holder) if holder

    owner = Contact.find_by(id: share.owner_id, account_id: @contact.account_id) if share.owner_id
    route(owner, recorded_share_conversation(owner, share), :booking_chat) if owner
  end

  def route(contact, conversation, kind) = Reminders::PatientSubjectGuard::Route.new(contact: contact, conversation: conversation, kind: kind)

  def recorded_share_conversation(owner, share)
    Conversation.find_by(id: share.conversation_id, account_id: owner.account_id, contact_id: owner.id) if share.conversation_id
  end

  def hint_json(hint)
    return if hint.blank?

    previous = Contact.find_by(id: hint['previous_holder_contact_id'], account_id: @contact.account_id)
    siblings = Contact.where(account_id: @contact.account_id, id: Array(hint['candidate_contact_ids'])).where.not(id: @contact.id)
    { masked_phone: Contacts::SharedPhone.mask(hint['phone']), reason: hint['reason'], detected_at: hint['detected_at'],
      previous_holder: previous && { id: previous.id, name: previous.name },
      siblings: siblings.map { |sibling| { id: sibling.id, name: sibling.name } } }
  end

  def preview_json(phone)
    previous = Contacts::SharedPhonePromotionService.previous_holder_for(@contact, phone)
    Contacts::NumberHistoryTransferPreview.new(account: @contact.account, phone: phone, card: @contact, previous_holder: previous).as_json
                                          .merge(masked_phone: Contacts::SharedPhone.mask(phone))
  end
end
