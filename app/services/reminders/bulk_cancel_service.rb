class Reminders::BulkCancelService
  CANCELLABLE_STATUSES = %w[draft pending].freeze

  attr_reader :account, :remindable, :reminder_group, :actor, :reason, :metadata

  def initialize(account:, remindable:, reminder_group: nil, actor: nil, reason: nil, metadata: {})
    @account = account
    @remindable = remindable
    @reminder_group = reminder_group
    @actor = actor
    @reason = reason.presence || 'Cancelled by automation'
    @metadata = (metadata || {}).to_h.stringify_keys
  end

  def perform
    ensure_account_boundary!

    cancelled_count = 0
    cancellable_scope.find_each do |reminder|
      cancelled_count += 1 if cancel_reminder(reminder)
    end

    cancelled_count
  end

  private

  def cancellable_scope
    scope = account.reminders.where(remindable: remindable, status: cancellable_status_values)
    return scope if reminder_group.blank?

    scope.where(reminder_group: reminder_group)
  end

  def cancellable_status_values
    Reminder.statuses.slice(*CANCELLABLE_STATUSES).values
  end

  def cancel_reminder(reminder)
    reminder.with_lock do
      return false unless reminder.draft? || reminder.pending?

      reminder.update!(
        status: :cancelled,
        cancelled_at: Time.current,
        last_error: reason,
        metadata: reminder.metadata.to_h.merge(audit_metadata)
      )
      true
    end
  end

  def audit_metadata
    {
      'cancelled_via' => metadata['cancelled_via'] || 'bulk_cancel_service',
      'cancelled_reason' => reason,
      'cancelled_at' => Time.current.iso8601,
      'cancelled_by_type' => actor&.class&.name,
      'cancelled_by_id' => actor&.id
    }.compact.merge(metadata)
  end

  def ensure_account_boundary!
    raise ArgumentError, 'remindable is required' if remindable.blank?
    raise ArgumentError, 'remindable does not belong to account' unless belongs_to_account?(remindable)
    return if reminder_group.blank?
    return if reminder_group.account_id == account.id

    raise ArgumentError, 'touch plan does not belong to account'
  end

  def belongs_to_account?(record)
    return record.account_id == account.id if record.respond_to?(:account_id)
    return record.account.id == account.id if record.respond_to?(:account) && record.account.present?

    false
  end
end
