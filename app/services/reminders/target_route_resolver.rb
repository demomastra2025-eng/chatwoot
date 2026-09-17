class Reminders::TargetRouteResolver
  ROUTE_REASSIGNMENT_REQUIRED = 'ROUTE_REASSIGNMENT_REQUIRED'.freeze
  ROUTE_REASSIGNMENT_MESSAGE = 'Touch target is not deliverable for the selected inbox'.freeze
  CURRENT_IDENTITY_CHANNEL_TYPES = %w[Channel::Email Channel::Sms Channel::TwilioSms Channel::Whatsapp].freeze

  attr_reader :reminder

  def initialize(reminder:)
    @reminder = reminder
  end

  def perform
    hydrate_source_context
    normalize_delivery_target
    reminder
  end

  private

  def hydrate_source_context
    reminder.conversation ||= source_conversation if source_conversation_matches_contact?
    reminder.target_contact ||= source_contact
    reminder.target_inbox ||= source_conversation&.inbox
  end

  def normalize_delivery_target
    return if reminder.target_inbox.blank?
    return mark_route_reassignment_required if reminder.target_contact.blank?
    return if explicit_target_associations_invalid?

    contact_inbox = resolved_contact_inbox
    return mark_route_reassignment_required if contact_inbox.blank?

    reminder.target_contact_inbox = contact_inbox
    unless conversation_matches_contact_inbox?(reminder.target_conversation, contact_inbox)
      reminder.target_conversation = resolved_target_conversation(contact_inbox)
    end
    reminder.clear_route_error!
    log_outcome(status: 'succeeded')
  end

  def resolved_contact_inbox
    return reminder.target_contact_inbox if deliverable_contact_inbox?(reminder.target_contact_inbox)

    source_id = resolved_source_id
    return if source_id.blank? && current_identity_required?
    return latest_unversioned_contact_inbox if source_id.blank?

    Outbound::ContactInboxResolver.new(
      inbox: reminder.target_inbox,
      contact: reminder.target_contact,
      source_id: source_id
    ).perform
  end

  def latest_unversioned_contact_inbox
    reminder.target_contact.contact_inboxes.where(inbox_id: reminder.target_inbox_id).order(updated_at: :desc).first
  end

  def explicit_target_associations_invalid?
    invalid_explicit_contact_inbox? || invalid_explicit_conversation?
  end

  def invalid_explicit_contact_inbox?
    reminder.target_contact_inbox.present? && !valid_contact_inbox?(reminder.target_contact_inbox)
  end

  def invalid_explicit_conversation?
    reminder.target_conversation.present? && !valid_conversation?(reminder.target_conversation)
  end

  def valid_contact_inbox?(contact_inbox)
    contact_inbox.present? &&
      contact_inbox.contact_id == reminder.target_contact_id &&
      contact_inbox.inbox_id == reminder.target_inbox_id &&
      contact_inbox.inbox&.account_id == reminder.account_id
  end

  def deliverable_contact_inbox?(contact_inbox)
    return false unless valid_contact_inbox?(contact_inbox)
    return false if resolved_source_id.blank? && current_identity_required?

    resolved_source_id.blank? || contact_inbox.source_id.to_s == resolved_source_id.to_s
  end

  def current_identity_required?
    reminder.target_inbox&.channel_type.in?(CURRENT_IDENTITY_CHANNEL_TYPES)
  end

  def valid_conversation?(conversation)
    conversation.present? &&
      conversation.account_id == reminder.account_id &&
      conversation.contact_id == reminder.target_contact_id &&
      conversation.inbox_id == reminder.target_inbox_id &&
      valid_contact_inbox?(conversation.contact_inbox)
  end

  def conversation_matches_contact_inbox?(conversation, contact_inbox)
    valid_conversation?(conversation) && conversation.contact_inbox_id == contact_inbox.id
  end

  def source_conversation_matches_target?(contact_inbox)
    source_conversation.present? &&
      source_conversation.account_id == reminder.account_id &&
      source_conversation.inbox_id == reminder.target_inbox_id &&
      source_conversation.contact_id == reminder.target_contact_id &&
      source_conversation.contact_inbox_id == contact_inbox.id
  end

  def resolved_target_conversation(contact_inbox)
    return source_conversation if source_conversation_matches_target?(contact_inbox)

    contact_inbox.conversations.where.not(status: :resolved).order(created_at: :desc).first
  end

  def resolved_source_id
    @resolved_source_id ||= Campaigns::TargetResolver.new(
      inbox: reminder.target_inbox,
      contact: reminder.target_contact
    ).resolve
  end

  def source_conversation_matches_contact?
    source_conversation.present? &&
      source_contact.present? &&
      source_conversation.contact_id == source_contact.id
  end

  def mark_route_reassignment_required
    reminder.target_contact_inbox = nil
    reminder.target_conversation = nil
    reminder.mark_route_reassignment_required!
    log_outcome(status: 'skipped', error_code: ROUTE_REASSIGNMENT_REQUIRED)
  end

  def log_outcome(status:, error_code: nil)
    Rails.logger.info(
      {
        event: 'reminder_target_route_resolution',
        status: status,
        error_code: error_code,
        account_id: reminder.account_id,
        reminder_id: reminder.id,
        remindable_type: reminder.remindable_type,
        remindable_id: reminder.remindable_id,
        target_inbox_id: reminder.target_inbox_id
      }.compact.to_json
    )
  end

  def source_contact
    @source_contact ||= source_route.first || source_conversation&.contact
  end

  def source_conversation
    @source_conversation ||= source_route.last || reminder.conversation
  end

  def source_route
    entity = reminder.remindable
    @source_route ||= case entity
                      when Conversation
                        [entity.contact, entity]
                      when Scheduling::Appointment
                        [entity.contact, entity.conversation]
                      when Crm::Deal
                        [deal_contact(entity), entity.originating_conversation]
                      when Crm::Task
                        [task_contact(entity), entity.originating_conversation]
                      else
                        [nil, nil]
                      end
  end

  def deal_contact(deal)
    deal.primary_contact || deal.contacts.first
  end

  def task_contact(task)
    task.deal&.contacts&.first
  end
end
