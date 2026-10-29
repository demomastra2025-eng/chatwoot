class Reminders::CancelSuppressedContactTouchesService
  OPEN_REMINDER_STATUSES = %w[draft pending].freeze
  OPEN_ENROLLMENT_STATUSES = %w[active paused].freeze

  def initialize(contact:)
    @contact = contact
    @account = contact.account
  end

  def perform
    return 0 unless contact.automation_notifications_suppressed? && account.present?

    cancelled = cancel_open_reminders
    cancel_open_enrollments!
    cancelled
  end

  private

  attr_reader :account, :contact

  def cancel_open_reminders
    cancelled = 0
    candidate_reminders_scope.find_each do |reminder|
      cancelled += 1 if Reminders::SuppressedContactPolicy.new(reminder: reminder).cancel_if_suppressed!
    rescue StandardError => e
      ChatwootExceptionTracker.new(e, account: account).capture_exception
    end
    cancelled
  end

  def cancel_open_enrollments!
    candidate_enrollments_scope.find_each do |enrollment|
      Reminders::SuppressedContactPolicy.cancel_enrollment_if_suppressed!(enrollment)
    rescue StandardError => e
      ChatwootExceptionTracker.new(e, account: account).capture_exception
    end
  end

  def candidate_reminders_scope
    base = account.reminders.where(status: OPEN_REMINDER_STATUSES)
    scopes = [
      base.where(target_contact_id: contact.id),
      base.where(remindable_type: 'Contact', remindable_id: contact.id),
      base.where(remindable_type: 'Scheduling::Appointment', remindable_id: appointment_ids_scope),
      base.where(remindable_type: 'Conversation', remindable_id: conversation_ids_scope),
      base.where(conversation_id: conversation_ids_scope),
      base.where(target_conversation_id: conversation_ids_scope),
      base.where(remindable_type: 'Crm::Deal', remindable_id: deal_ids_scope),
      base.where(remindable_type: 'Crm::Task', remindable_id: task_ids_scope)
    ]
    scopes.reduce { |combined, scope| combined.or(scope) }
  end

  def candidate_enrollments_scope
    base = account.touch_plan_enrollments.where(status: OPEN_ENROLLMENT_STATUSES)
    scopes = [
      base.where(remindable_type: 'Contact', remindable_id: contact.id),
      base.where(remindable_type: 'Scheduling::Appointment', remindable_id: appointment_ids_scope),
      base.where(remindable_type: 'Conversation', remindable_id: conversation_ids_scope),
      base.where(remindable_type: 'Crm::Deal', remindable_id: deal_ids_scope),
      base.where(remindable_type: 'Crm::Task', remindable_id: task_ids_scope)
    ]
    scopes.reduce { |combined, scope| combined.or(scope) }
  end

  def appointment_ids_scope
    Scheduling::Appointment
      .where(account_id: account.id)
      .where('contact_id = :id OR patient_contact_id = :id', id: contact.id)
      .select(:id)
  end

  def conversation_ids_scope
    account.conversations.where(contact_id: contact.id).select(:id)
  end

  def deal_ids_scope
    Crm::DealContact.where(account_id: account.id, contact_id: contact.id).select(:deal_id)
  end

  def task_ids_scope
    Crm::Task.where(account_id: account.id, deal_id: deal_ids_scope).select(:id)
  end
end
