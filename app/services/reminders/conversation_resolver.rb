class Reminders::ConversationResolver
  attr_reader :reminder

  def initialize(reminder:)
    @reminder = reminder
  end

  def perform
    return target_conversation if target_conversation.present? && !target_conversation.resolved?
    return reminder.conversation if reminder.conversation.present? && !reminder.conversation.resolved?

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
    return reminder.target_contact_inbox if reminder.target_contact_inbox.present?

    inbox = reminder.target_inbox
    contact = reminder.target_contact

    raise Reminders::UndeliverableTargetError, 'Touch target inbox is missing' if inbox.blank?
    raise Reminders::UndeliverableTargetError, 'Touch target contact is missing' if contact.blank?

    contact_inbox = Outbound::ContactInboxResolver.new(
      inbox: inbox,
      contact: contact
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
end
