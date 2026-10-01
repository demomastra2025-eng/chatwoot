class Reminders::PatientSubjectGuard
  # kind: :own (the card's own primary number), :holder (the chat of the contact that holds the card's доп. номер as
  # primary), :booking_chat (hidden-number share: the chat where the booking was made), :unroutable (an appointment
  # without a booking chat whose доп. номер has no verified phone chat: nothing is sent, the touch needs a route),
  # :appointment_contact (fallback, v7 behaviour), :entity (not an appointment).
  Route = Data.define(:contact, :conversation, :kind) do
    def unroutable? = kind == :unroutable
  end
  UNROUTABLE = Route.new(contact: nil, conversation: nil, kind: :unroutable)
  # Channels whose chat identity is the phone number itself, verified by the channel (the sender owns the number).
  PHONE_DELIVERY_CHANNELS = %w[Channel::Whatsapp Channel::WhatsappWeb Channel::TwilioSms Channel::Sms].freeze

  def self.separate_patient?(remindable)
    return false unless remindable.is_a?(Scheduling::Appointment)

    return remindable.patient_contact_id != remindable.contact_id if remindable.patient_contact_id.present?

    Integrations::Medelement::AppointmentPatientIdentity.owned?(remindable.custom_attributes)
  end

  # M3, evaluated whenever an open touch is hydrated, synced or sent (a sent touch keeps its route, see
  # Reminder#delivery_route_settled?; a failed send is never re-sent over another route):
  #   1. the separate card's own primary number;
  #   2. else its доп. номер through the chat of the contact that holds that number as primary, when that chat is tied
  #      to the number in the touch inbox (the booking chat's contact, a holder chatting from the number there, or the
  #      share owner's recorded booking chat);
  #   3. else, nobody reachable holds it (hidden-number share): the chat where the booking was made;
  #   4. else the appointment contact (v7 behaviour).
  # An appointment without a booking chat (MedElement import, booking from a contact page) reaches a доп. номер only
  # through the holder's own phone chat on that number (see chatless_route); otherwise it is :unroutable and nothing is
  # sent. The appointment's own contact/conversation stay untouched; only the notification route changes.
  def self.notification_route(remindable, inbox: nil)
    return Route.new(contact: remindable.try(:contact), conversation: nil, kind: :entity) unless remindable.is_a?(Scheduling::Appointment)

    fallback = Route.new(contact: remindable.contact, conversation: remindable.conversation, kind: :appointment_contact)
    patient = separate_patient_card(remindable)
    return fallback if patient.blank?

    patient_route(remindable, patient, inbox) || fallback
  end

  def self.patient_route(appointment, patient, inbox)
    return Route.new(contact: patient, conversation: nil, kind: :own) if own_number?(appointment, patient)

    share = Contacts::SharedPhone.share_of(patient)
    return if share.blank?
    return chatless_route(patient, share, inbox) if appointment.conversation.blank?

    holder_route(appointment, patient, share, inbox || appointment.conversation.inbox) || booking_route(appointment)
  end
  private_class_method :patient_route

  # sc8rv1 round 3 H2c: without a booking chat there is no chat the family number was given in, and the latest chat
  # of the share owner or holder may be one that anyone can attach to it without proving the number (widget identify
  # or pre-chat by email, public API, lead forms, email). Such an appointment reaches the доп. номер only through the
  # contact that holds it as primary, on a channel whose chat identity is the number itself (WhatsApp, WhatsApp Web,
  # SMS): in the touch inbox when the touch has one (its chat on the number there, or a new one on the number), else the
  # holder's latest chat on the number. A hidden-number share (nobody holds it) and any other inbox fail closed.
  def self.chatless_route(patient, share, inbox)
    holder = Contacts::SharedPhone.primary_holder(account_id: patient.account_id, phone: share.phone, excluding: [patient.id])
    return UNROUTABLE if holder.blank?
    return phone_inbox_route(holder, share.phone, inbox) if inbox

    conversation = holder_phone_conversation(holder, share.phone)
    conversation ? Route.new(contact: holder, conversation: conversation, kind: :holder) : UNROUTABLE
  end
  private_class_method :chatless_route

  # The holder's latest chat (open first) whose channel identity is the number itself; nil when it has none.
  def self.holder_phone_conversation(holder, phone)
    identity_conversation(holder, phone_identities(holder, phone, nil))
  end

  def self.phone_inbox_route(holder, phone, inbox)
    return UNROUTABLE unless PHONE_DELIVERY_CHANNELS.include?(inbox.channel_type)

    Route.new(contact: holder, conversation: identity_conversation(holder, phone_identities(holder, phone, inbox)), kind: :holder)
  end
  private_class_method :phone_inbox_route

  def self.phone_identities(holder, phone, inbox)
    scope = Contacts::SharedPhone.identifying_contact_inboxes(account_id: holder.account_id, phone: phone, owner_ids: [holder.id])
                                 .joins(:inbox).where(inboxes: { channel_type: PHONE_DELIVERY_CHANNELS })
    inbox ? scope.where(inbox_id: inbox.id) : scope
  end
  private_class_method :phone_identities

  def self.notification_contact(remindable, inbox: nil)
    notification_route(remindable, inbox: inbox).contact
  end

  # True while the touch is routed to the separate patient card itself (its own primary number).
  def self.patient_route?(reminder)
    appointment = reminder.remindable
    separate_patient?(appointment) && appointment.patient_contact_id.present? &&
      reminder.target_contact_id == appointment.patient_contact_id
  end

  # Every route of a separate patient's appointment (own number, holder, booking chat, share owner) resolves its
  # ContactInbox without claiming or renaming another contact's chat identity: a collision is a visible failure or a
  # reassignment draft, never a silent move of someone else's chat.
  def self.no_steal_route?(reminder)
    separate_patient?(reminder.remindable)
  end

  # A separate patient's own number never takes over another contact's chat identity: when a ContactInbox of someone
  # else already carries this source in the delivery inbox, the touch route must not claim or rename it.
  def self.foreign_chat_identity?(inbox:, contact:, source_id:)
    return false if inbox.blank? || contact.blank? || source_id.blank?

    ContactInbox.where(inbox_id: inbox.id, source_id: source_id.to_s).where.not(contact_id: contact.id).exists?
  end

  # Lookup-or-insert of a separate patient's own ContactInbox (the block runs the regular resolver/builder). Returns
  # nil when the source is, or concurrently became, another contact's chat identity: it is never claimed or renamed.
  # Only the insert attempt runs in a savepoint. A lost insert race (the builder's own recovery cannot run inside the
  # aborted savepoint) rolls back just that savepoint and re-reads the committed winner, so a concurrent insert of the
  # same patient's ContactInbox is reused. Any other database error propagates to the caller as a transient failure.
  def self.own_contact_inbox(inbox:, contact:, source_id:, &)
    return if foreign_chat_identity?(inbox: inbox, contact: contact, source_id: source_id)

    ContactInbox.transaction(requires_new: true, &)
  rescue ActiveRecord::StatementInvalid => e
    raise unless contact_inbox_insert_race?(e)

    winner = ContactInbox.find_by(inbox_id: inbox.id, source_id: source_id.to_s)
    raise if winner.blank?

    winner if winner.contact_id == contact.id
  end

  def self.contact_inbox_insert_race?(error)
    error.is_a?(ActiveRecord::RecordNotUnique) || error.cause.is_a?(PG::InFailedSqlTransaction)
  end
  private_class_method :contact_inbox_insert_race?

  # Ordinary replies belong to their sender: only the separate patient's own contact releases that patient's
  # auto-cancel touches, while a reply over the shared owner's route never does.
  def self.foreign_reply?(remindable, message)
    return false unless separate_patient?(remindable)
    return true if remindable.patient_contact_id.blank? || message&.sender_type != 'Contact'

    message.sender_id != remindable.patient_contact_id
  end

  def self.separate_patient_card(appointment)
    return unless separate_patient?(appointment)

    patient = appointment.patient_contact
    patient if patient.present? && patient.account_id == appointment.account_id
  end
  private_class_method :separate_patient_card

  # The card's own number is used unless it is still the booking chat contact's number (v7 rule). A stranger chatting
  # from it does not re-route the touch: that touch fails visibly or needs reassignment (no takeover, no silent re-route).
  def self.own_number?(appointment, patient)
    patient.phone_number.present? && !shared_number?(appointment.contact, patient.phone_number)
  end
  private_class_method :own_number?

  # A holder other than the booking chat's contact is used only through a chat that is provably tied to the number in
  # the touch inbox:
  #   - a chat whose channel source is the number (phone channels, voice): the channel itself verified the sender;
  #   - else only the conversation recorded with the share (SHARED_CONVERSATION_KEY: the share owner's own booking chat).
  # In a channel without phone identities (widget, API, email, social) anyone can attach a chat to the holder without
  # proving the number (widget identify or pre-chat by phone merges the visitor into the holder, a public API create by
  # phone attaches to it), so "the holder's latest chat in that inbox" is never used, and no new chat is opened for a
  # holder there: the touch stays on the booking chat.
  def self.holder_route(appointment, patient, share, inbox)
    holder = Contacts::SharedPhone.primary_holder(account_id: patient.account_id, phone: share.phone, excluding: [patient.id])
    return if holder.blank?
    return Route.new(contact: holder, conversation: appointment.conversation, kind: :holder) if holder.id == appointment.contact_id
    return if inbox.blank?

    identities = holder_identities(holder, share.phone, inbox)
    return Route.new(contact: holder, conversation: identity_conversation(holder, identities), kind: :holder) if identities.exists?

    recorded = recorded_share_conversation(holder, share, inbox)
    Route.new(contact: holder, conversation: recorded, kind: :holder) if recorded
  end
  private_class_method :holder_route

  def self.holder_identities(holder, phone, inbox)
    Contacts::SharedPhone.identifying_contact_inboxes(account_id: holder.account_id, phone: phone, owner_ids: [holder.id]).where(inbox_id: inbox.id)
  end
  private_class_method :holder_identities

  # The holder's chat on the number itself (latest open one, else the latest); nil lets the resolver reopen that same
  # ContactInbox, which is the number's own chat identity.
  def self.identity_conversation(holder, identities)
    scope = Conversation.where(account_id: holder.account_id, contact_id: holder.id, contact_inbox_id: identities.select(:id))
    scope.where.not(status: :resolved).order(last_activity_at: :desc, id: :desc).first || scope.order(last_activity_at: :desc, id: :desc).first
  end
  private_class_method :identity_conversation

  def self.recorded_share_conversation(holder, share, inbox)
    return if share.conversation_id.blank? || holder.id != share.owner_id

    Conversation.find_by(id: share.conversation_id, account_id: holder.account_id, contact_id: holder.id, inbox_id: inbox.id)
  end
  private_class_method :recorded_share_conversation

  def self.booking_route(appointment)
    Route.new(contact: appointment.contact, conversation: appointment.conversation, kind: :booking_chat)
  end
  private_class_method :booking_route

  # The number is still the shared one when it is the communication owner's primary number or one of the owner's chat
  # identities (the owner may chat from the family number while its phone field holds another number).
  def self.shared_number?(owner, phone_number)
    return false if owner.blank?
    return true if owner.phone_number == phone_number

    owner.contact_inboxes.exists?(source_id: [phone_number, phone_number.delete('+'), "whatsapp:#{phone_number}"])
  end
  private_class_method :shared_number?
end
