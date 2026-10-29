class Reminders::SuppressedContactPolicy
  MUTED_CANCEL_REASON = 'автоуведомления отключены для контакта'.freeze
  MUTED_CANCELLED_VIA = 'contact_notifications_muted'.freeze
  BLOCKED_CANCEL_REASON = 'контакт заблокирован'.freeze
  BLOCKED_CANCELLED_VIA = 'contact_blocked'.freeze
  UNSCOPED_PROCESSING_CLAIM = Object.new.freeze

  def self.suppressed_contact_for(record_or_contacts, account_id: nil)
    items = Array.wrap(record_or_contacts).compact
    return if items.empty?

    in_memory = in_memory_suppressed_contacts(items)
    return preferred_suppressed_contact(in_memory) if in_memory.any?

    preferred_suppressed_contact(persisted_suppressed_contacts(items, account_id))
  end

  def self.in_memory_suppressed_contacts(items)
    items.select { |item| item.is_a?(Contact) && item.new_record? && item.automation_notifications_suppressed? }
  end
  private_class_method :in_memory_suppressed_contacts

  def self.persisted_suppressed_contacts(items, account_id)
    ids = Contact.automation_contact_ids_for(items)
    return [] if ids.empty?

    resolved_account_id = account_id || (items.one? ? items.first.try(:account_id) : nil)
    scope = resolved_account_id.present? ? Contact.where(account_id: resolved_account_id) : Contact.all
    scope.where(id: ids).where('notifications_muted = TRUE OR blocked = TRUE').to_a
  end
  private_class_method :persisted_suppressed_contacts

  def self.preferred_suppressed_contact(contacts)
    contacts.find(&:notifications_muted?) || contacts.first
  end
  private_class_method :preferred_suppressed_contact

  def self.cancellation_details_for(contact)
    if contact&.notifications_muted?
      [MUTED_CANCEL_REASON, MUTED_CANCELLED_VIA]
    else
      [BLOCKED_CANCEL_REASON, BLOCKED_CANCELLED_VIA]
    end
  end

  def self.cancel_enrollment_if_suppressed!(enrollment, extra_metadata: {})
    return false unless %w[active paused].include?(enrollment.status)
    return false if enrollment.remindable.blank?

    contact = suppressed_contact_for(enrollment.remindable, account_id: enrollment.account_id)
    return false if contact.blank?

    reason, via = cancellation_details_for(contact)
    Reminders::CancelEnrollmentService.new(
      enrollment: enrollment,
      reason: reason,
      metadata: extra_metadata.stringify_keys.merge(
        'cancelled_via' => via,
        'suppressed_contact_id' => contact.id
      )
    ).perform
    true
  end

  def initialize(reminder:, processing_claim: UNSCOPED_PROCESSING_CLAIM)
    @reminder = reminder
    @execution_scoped = !processing_claim.equal?(UNSCOPED_PROCESSING_CLAIM)
    @processing_claim = @execution_scoped ? processing_claim : nil
  end

  def suppressed?
    cancellable_state? && suppressed_contact.present?
  end

  def cancel_if_suppressed!
    return false unless reminder.persisted? && suppressed?

    reminder.with_lock do
      reminder.reload
      reset_memoized_contact!
      next false unless suppressed?

      cancel!
      true
    end
  end

  private

  attr_reader :processing_claim, :reminder

  def cancellable_state?
    return false if reminder.delivery_materialized?
    return reminder.draft? || reminder.pending? unless @execution_scoped

    reminder.processing? && reminder.processing_claim_token == processing_claim
  end

  def reset_memoized_contact!
    @suppressed_contact = nil
    @suppressed_contact_checked = false
  end

  def suppressed_contact
    return @suppressed_contact if @suppressed_contact_checked

    @suppressed_contact_checked = true
    @suppressed_contact = self.class.suppressed_contact_for(reminder, account_id: reminder.account_id)
  end

  def cancel!
    contact = suppressed_contact
    reason, via = self.class.cancellation_details_for(contact)
    cancelled_at = Time.current
    reminder.update!(
      status: :cancelled,
      cancelled_at: cancelled_at,
      processing_started_at: nil,
      last_error: reason,
      metadata: reminder.metadata.to_h.merge(
        'cancelled_via' => via,
        'cancelled_reason' => reason,
        'cancelled_at' => cancelled_at.iso8601(6),
        'suppressed_contact_id' => contact.id
      )
    )
  end
end
