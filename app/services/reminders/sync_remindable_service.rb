class Reminders::SyncRemindableService
  ROUTE_REASSIGNMENT_REQUIRED = 'Touch requires channel reassignment after entity update'.freeze

  attr_reader :remindable

  def initialize(remindable:)
    @remindable = remindable
  end

  def perform
    remindable.reminders.open_statuses.find_each do |touch|
      sync_touch!(touch)
    rescue StandardError => e
      ChatwootExceptionTracker.new(e, account: remindable.account).capture_exception
    end
  end

  private

  def sync_touch!(touch)
    touch.assign_attributes(sync_attributes_for(touch))
    touch.scheduled_at_will_change! if touch.relative?
    return unless touch.changed?

    touch.save!
    touch.approve! if touch.reload.draft? && touch.ready_for_pending?
  end

  # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
  def sync_attributes_for(touch)
    attrs = {}

    owner = desired_owner
    contact = desired_contact
    entity_conversation = desired_entity_conversation

    attrs[:owner] = owner if touch.owner_id != owner&.id
    attrs[:conversation] = entity_conversation if touch.conversation_id != entity_conversation&.id

    if contact.present? && touch.target_contact_id != contact.id
      attrs[:target_contact] = contact
      attrs.merge!(route_sync_attributes(touch, contact))
    elsif contact.blank? && touch.target_contact_id.present?
      attrs[:target_contact] = nil
      attrs[:target_contact_inbox] = nil
      attrs[:target_conversation] = nil
      attrs[:status] = :draft
      attrs[:last_error] = ROUTE_REASSIGNMENT_REQUIRED
    elsif route_invalid_for_current_contact?(touch, contact)
      attrs.merge!(route_sync_attributes(touch, contact))
    end

    attrs
  end
  # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

  def route_sync_attributes(touch, contact)
    return {} if touch.target_inbox_id.blank?
    return {} if contact.blank?

    if contactable_inbox_ids(contact).include?(touch.target_inbox_id)
      {
        target_contact_inbox: contact.contact_inboxes.find_by(inbox_id: touch.target_inbox_id),
        target_conversation: keep_target_conversation?(touch, contact) ? touch.target_conversation : nil,
        last_error: nil
      }
    else
      {
        target_contact_inbox: nil,
        target_conversation: nil,
        status: :draft,
        last_error: ROUTE_REASSIGNMENT_REQUIRED
      }
    end
  end

  def route_invalid_for_current_contact?(touch, contact)
    return false if touch.target_inbox_id.blank? || contact.blank?

    !contactable_inbox_ids(contact).include?(touch.target_inbox_id)
  end

  def contactable_inbox_ids(contact)
    @contactable_inbox_ids ||= {}
    @contactable_inbox_ids[contact.id] ||= Contacts::ContactableInboxesService.new(contact: contact).get.map do |item|
      item[:inbox].id
    end
  end

  def keep_target_conversation?(touch, contact)
    touch.target_conversation.present? &&
      touch.target_conversation.contact_id == contact.id &&
      touch.target_conversation.inbox_id == touch.target_inbox_id
  end

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
      remindable.contacts.first
    when Crm::Task
      remindable.deal&.contacts&.first
    end
  end

  def desired_entity_conversation
    case remindable
    when Conversation
      remindable
    when Crm::Deal, Crm::Task
      remindable.originating_conversation
    when Scheduling::Appointment
      remindable.conversation
    end
  end
end
