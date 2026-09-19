class Reminders::SyncRemindableService
  attr_reader :remindable

  def initialize(remindable:, allow_processing: false)
    @remindable = remindable
    @allow_processing = allow_processing
  end

  def perform
    remindable.reminders.open_statuses.find_each do |touch|
      perform_for(touch)
    end
  end

  def perform_for(touch, lock: true, raise_errors: false)
    lock ? touch.with_lock { sync_locked_touch!(touch) } : sync_locked_touch!(touch)
  rescue StandardError => e
    raise if raise_errors

    ChatwootExceptionTracker.new(e, account: remindable.account).capture_exception
  end

  private

  def refreshable_processing_touch?(touch)
    @allow_processing && touch.processing? && !touch.delivery_materialized?
  end

  def sync_locked_touch!(touch)
    touch.reload
    return unless syncable_touch?(touch)

    touch.assign_attributes(sync_attributes_for(touch))
    clear_stale_target_routes(touch)
    Reminders::TargetRouteResolver.new(reminder: touch).perform
    touch.scheduled_at_will_change! if touch.relative_schedule_stale?
    persist_sync!(touch) if touch.changed?
  end

  def syncable_touch?(touch)
    touch.editable? || refreshable_processing_touch?(touch)
  end

  def persist_sync!(touch)
    touch.save!
    touch.approve! if touch.draft? && touch.ready_for_pending?
  end

  def clear_stale_target_routes(touch)
    if touch.target_contact_inbox.present? &&
       (touch.target_contact_inbox.contact_id != touch.target_contact_id || touch.target_contact_inbox.inbox_id != touch.target_inbox_id)
      touch.target_contact_inbox = nil
    end

    return if touch.target_conversation.blank?
    return if touch.target_conversation.contact_id == touch.target_contact_id &&
              touch.target_conversation.inbox_id == touch.target_inbox_id

    touch.target_conversation = nil
  end

  # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
  def sync_attributes_for(touch)
    attrs = {}

    owner = desired_owner
    contact = desired_contact
    entity_conversation = desired_entity_conversation

    attrs[:owner] = owner if touch.owner_id != owner&.id
    attrs[:conversation] = entity_conversation if touch.conversation_id != entity_conversation&.id

    if contact.present? && touch.target_contact_id != contact.id
      attrs[:target_contact] = contact
      attrs[:target_contact_inbox] = nil
      attrs[:target_conversation] = nil
    elsif contact.blank? && touch.target_contact_id.present?
      attrs[:target_contact] = nil
      attrs[:target_contact_inbox] = nil
      attrs[:target_conversation] = nil
      attrs[:status] = :draft
    end

    attrs
  end
  # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

  def desired_owner
    case remindable
    when Conversation, Crm::Task
      remindable.assignee
    when Crm::Deal
      remindable.owner
    when Scheduling::Appointment
      remindable.created_by
    end
  end

  def desired_contact
    case remindable
    when Conversation, Scheduling::Appointment
      remindable.contact
    when Crm::Deal
      remindable.primary_contact || remindable.contacts.first
    when Crm::Task
      remindable.deal&.contacts&.first
    end
  end

  def desired_entity_conversation
    case remindable
    when Conversation
      remindable
    when Crm::Deal
      matching_conversation(remindable.originating_conversation)
    when Crm::Task
      remindable.originating_conversation
    when Scheduling::Appointment
      matching_conversation(remindable.conversation)
    end
  end

  def matching_conversation(conversation)
    return if conversation.blank?

    conversation if conversation.contact_id == desired_contact&.id
  end
end
