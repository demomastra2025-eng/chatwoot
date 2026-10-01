class Reminders::TargetRouteResolver
  ROUTE_REASSIGNMENT_REQUIRED = 'ROUTE_REASSIGNMENT_REQUIRED'.freeze
  ROUTE_REASSIGNMENT_MESSAGE = 'Touch target is not deliverable for the selected inbox'.freeze
  CURRENT_IDENTITY_CHANNEL_TYPES = %w[Channel::Email Channel::Sms Channel::TwilioSms Channel::Whatsapp].freeze

  attr_reader :reminder

  def initialize(reminder:)
    @reminder = reminder
  end

  def perform
    return clear_unroutable_patient_route if unroutable_patient_route?

    hydrate_source_context
    normalize_delivery_target
    reminder
  end

  private

  # A separate patient's appointment without a booking chat whose доп. номер has no verified phone chat (H2c): the
  # touch keeps no contact, ContactInbox or conversation and stays a visible draft that needs a route (staff choose a
  # phone inbox, or the patient gets an own number). No other chat of the holder or share owner is used.
  def unroutable_patient_route?
    reminder.remindable.is_a?(Scheduling::Appointment) && !reminder.delivery_route_settled? && reminder.notification_route.unroutable?
  end

  def clear_unroutable_patient_route
    reminder.target_contact = nil
    mark_route_reassignment_required
    reminder
  end

  def hydrate_source_context
    reminder.align_notification_contact if reminder.target_contact.present?
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
    return patient_own_contact_inbox(source_id) if Reminders::PatientSubjectGuard.no_steal_route?(reminder)

    contact_inbox_for(source_id)
  end

  def contact_inbox_for(source_id)
    Outbound::ContactInboxResolver.new(
      inbox: reminder.target_inbox,
      contact: reminder.target_contact,
      source_id: source_id
    ).perform
  end

  # Every route of a separate patient's appointment gets a ContactInbox of its own contact, but never one that is
  # already another contact's chat identity in this inbox (that touch needs reassignment instead). The insert runs in a
  # savepoint and a lost race with the same contact's ContactInbox reuses the winner (see
  # PatientSubjectGuard.own_contact_inbox); other database errors propagate, so the per-touch sync savepoint rolls the
  # touch back instead of saving a reassignment draft.
  def patient_own_contact_inbox(source_id)
    Reminders::PatientSubjectGuard.own_contact_inbox(inbox: reminder.target_inbox, contact: reminder.target_contact, source_id: source_id) do
      contact_inbox_for(source_id)
    end
  rescue ActiveRecord::RecordInvalid => e
    Rails.logger.warn({ event: 'reminder_patient_contact_inbox_unavailable', reminder_id: reminder.id, error: e.class.name }.to_json)
    nil
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
                        route = Reminders::PatientSubjectGuard.notification_route(entity, inbox: reminder.target_inbox)
                        [route.contact, route.conversation || entity.conversation]
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
