class Reminders::ConversationResolver
  attr_reader :reminder

  def initialize(reminder:)
    @reminder = reminder
  end

  def perform
    return target_conversation if usable_conversation?(target_conversation)

    contact_inbox = ensure_contact_inbox!
    existing_conversation = contact_inbox.conversations.where.not(status: :resolved).order(created_at: :desc).first
    return existing_conversation if existing_conversation.present?

    create_conversation!(contact_inbox)
  end

  private

  def create_conversation!(contact_inbox)
    conversation = Conversation.create!(
      account_id: reminder.account_id,
      inbox_id: contact_inbox.inbox_id,
      contact_id: contact_inbox.contact_id,
      contact_inbox_id: contact_inbox.id,
      status: :open,
      additional_attributes: base_additional_attributes(contact_inbox)
    )
    conversation.update!(waiting_since: nil)
    conversation
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

    contact_inbox = Outbound::ContactInboxResolver.new(
      inbox: inbox,
      contact: contact,
      source_id: current_source_id
    ).perform

    raise Reminders::UndeliverableTargetError, 'Touch target is not deliverable for this inbox' if contact_inbox.blank?

    contact_inbox
  end

  def base_additional_attributes(contact_inbox)
    return { mail_subject: reminder.metadata['mail_subject'].presence || reminder.body.to_s.truncate(80) } if reminder.target_inbox&.email?
    return telegram_additional_attributes(contact_inbox) if reminder.target_inbox&.channel_type == 'Channel::Telegram'

    {}
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
