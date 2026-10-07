class Reminders::ConversationResolver
  PATIENT_NUMBER_TAKEN = 'Patient number already belongs to another contact in this inbox'.freeze

  attr_reader :reminder

  def initialize(reminder:)
    @reminder = reminder
  end

  def perform
    return target_conversation if usable_conversation?(target_conversation)

    contact_inbox = ensure_contact_inbox!
    existing_conversation = contact_inbox.conversations.where.not(status: :resolved).order(created_at: :desc).first
    return existing_conversation if existing_conversation.present?

    reusable_closed_conversation(contact_inbox) || create_conversation!(contact_inbox)
  end

  private

  # Every conversation of the chat is closed and an automated notification must not reopen any of them. It goes into the
  # latest closed conversation (its status is left alone) when the inbox keeps one conversation per contact, because the
  # patient's reply lands there too, or when that conversation is itself an earlier notification carrier. Otherwise
  # create_conversation! makes a new closed carrier. The highest id is used because the incoming-message services of the
  # chat channels route a reply to the highest id as well.
  def reusable_closed_conversation(contact_inbox)
    latest = contact_inbox.conversations.reorder(id: :desc).first
    return if latest.blank? || latest.contact_id != contact_inbox.contact_id
    return unless contact_inbox.inbox.lock_to_single_conversation? || latest.automated_outbound_conversation?
    return if telegram_inbox? && latest.additional_attributes.to_h['chat_id'].blank?

    refresh_mail_subject(latest)
    latest
  end

  # An earlier notification conversation is reused for every later touch, but ConversationReplyMailer sends each message under
  # the conversation's mail_subject, so a later touch must not go out under the subject of the first one. The subject is
  # written without callbacks: a closed conversation raises no event for it. Only a notification conversation is changed,
  # never the subject of a conversation of a person.
  def refresh_mail_subject(conversation)
    return unless reminder.target_inbox&.email? && conversation.automated_outbound_conversation?

    attributes = conversation.additional_attributes.to_h
    return if attributes['mail_subject'] == mail_subject

    conversation.update_columns(additional_attributes: attributes.merge('mail_subject' => mail_subject)) # rubocop:disable Rails/SkipsModelValidations
  end

  # A conversation that only carries the notification is created already closed and silent: it never shows up in the open
  # or pending lists and does not raise "new conversation" notifications, auto-assignment, automation or webhook events
  # and a CRM deal. A reply of the patient reopens it through the incoming message as for any closed conversation.
  # skip_runtime_events is set on this one record only: Current.suppress_runtime_events would also stop the delivery of
  # the message (Message#send_reply). A fresh instance is returned so that the flag does not leak into later updates.
  def create_conversation!(contact_inbox)
    conversation = Conversation.new(
      account_id: reminder.account_id,
      inbox_id: contact_inbox.inbox_id,
      contact_id: contact_inbox.contact_id,
      contact_inbox_id: contact_inbox.id,
      status: :resolved,
      additional_attributes: base_additional_attributes(contact_inbox).stringify_keys.merge(
        Conversation::AUTOMATED_OUTBOUND_ATTRIBUTE => true
      )
    )
    conversation.skip_runtime_events = true
    conversation.save!
    conversation.update!(waiting_since: nil)
    Conversation.find(conversation.id)
  end

  def ensure_contact_inbox!
    return reminder.target_contact_inbox if usable_contact_inbox?(reminder.target_contact_inbox)

    inbox = reminder.target_inbox
    contact = reminder.target_contact

    raise Reminders::UndeliverableTargetError, 'Touch target inbox is missing' if inbox.blank?
    raise Reminders::UndeliverableTargetError, 'Touch target contact is missing' if contact.blank?
    if current_source_id.blank? && current_identity_required?
      raise Reminders::UndeliverableTargetError, 'Touch target is not deliverable for this inbox'
    end

    contact_inbox = resolve_contact_inbox(inbox, contact)

    raise Reminders::UndeliverableTargetError, 'Touch target is not deliverable for this inbox' if contact_inbox.blank?

    contact_inbox
  end

  def resolve_contact_inbox(inbox, contact)
    resolver = Outbound::ContactInboxResolver.new(
      inbox: inbox,
      contact: contact,
      source_id: current_source_id
    )
    return resolver.perform if current_source_id.blank? || !Reminders::PatientSubjectGuard.no_steal_route?(reminder)

    patient_contact_inbox!(resolver, inbox, contact)
  end

  # A route of a separate patient's appointment never claims (or renames) a ContactInbox that is another contact's chat
  # identity in this inbox; such a touch fails visibly instead of being re-sent over any other route. A concurrent insert
  # of the same contact's ContactInbox is reused (see PatientSubjectGuard.own_contact_inbox).
  def patient_contact_inbox!(resolver, inbox, contact)
    contact_inbox = Reminders::PatientSubjectGuard.own_contact_inbox(inbox: inbox, contact: contact, source_id: current_source_id) do
      resolver.perform
    end
    raise Reminders::UndeliverableTargetError, PATIENT_NUMBER_TAKEN if contact_inbox.blank?

    contact_inbox
  rescue ActiveRecord::RecordInvalid => e
    raise Reminders::UndeliverableTargetError, "Patient number is not deliverable in this inbox (#{e.class.name})"
  end

  def base_additional_attributes(contact_inbox)
    return { mail_subject: mail_subject } if reminder.target_inbox&.email?
    return telegram_additional_attributes(contact_inbox) if telegram_inbox?

    {}
  end

  def mail_subject
    reminder.metadata['mail_subject'].presence || reminder.body.to_s.truncate(80)
  end

  def telegram_inbox?
    reminder.target_inbox&.channel_type == 'Channel::Telegram'
  end

  def telegram_additional_attributes(contact_inbox)
    latest_conversation = contact_inbox.conversations
                                       .order(last_activity_at: :desc, created_at: :desc, id: :desc)
                                       .first
    attributes = (latest_conversation&.additional_attributes || {}).slice('chat_id', 'business_connection_id')
    attributes['chat_id'] = attributes['chat_id'].presence || contact_inbox.source_id

    attributes
  end

  def target_conversation
    reminder.target_conversation
  end

  def usable_conversation?(conversation)
    conversation.present? && !conversation.resolved? &&
      conversation_matches_target?(conversation) &&
      usable_contact_inbox?(conversation.contact_inbox)
  end

  def conversation_matches_target?(conversation)
    conversation.account_id == reminder.account_id &&
      conversation.inbox_id == reminder.target_inbox&.id &&
      conversation.contact_id == reminder.target_contact&.id
  end

  def usable_contact_inbox?(contact_inbox)
    structurally_usable_contact_inbox?(contact_inbox) && source_identity_matches?(contact_inbox)
  end

  def structurally_usable_contact_inbox?(contact_inbox)
    contact_inbox.present? &&
      contact_inbox.inbox_id == reminder.target_inbox&.id &&
      contact_inbox.contact_id == reminder.target_contact&.id &&
      contact_inbox.inbox&.account_id == reminder.account_id
  end

  def source_identity_matches?(contact_inbox)
    return false if current_source_id.blank? && current_identity_required?

    current_source_id.blank? || contact_inbox.source_id.to_s == current_source_id.to_s
  end

  def current_identity_required?
    reminder.target_inbox&.channel_type.in?(Reminders::TargetRouteResolver::CURRENT_IDENTITY_CHANNEL_TYPES)
  end

  def current_source_id
    return @current_source_id if defined?(@current_source_id)

    @current_source_id = if reminder.target_inbox.present? && reminder.target_contact.present?
                           Campaigns::TargetResolver.new(
                             inbox: reminder.target_inbox,
                             contact: reminder.target_contact
                           ).resolve
                         end
  end
end
