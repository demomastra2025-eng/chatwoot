class Reminders::BulkCancelService
  CANCELLABLE_STATUSES = Reminder::OPEN_STATUSES.freeze
  ACTIVE_STATUSES = Reminder::OPEN_STATUSES.freeze

  attr_reader :account, :remindable, :reminder_group, :actor, :reason, :metadata

  def initialize(account:, remindable:, **options)
    @account = account
    @remindable = remindable
    @reminder_group = options[:reminder_group]
    @actor = options[:actor]
    @reason = options[:reason].presence || 'отменен автоматизацией'
    @metadata = (options[:metadata] || {}).to_h.stringify_keys
  end

  def perform
    perform_with_details[:cancelled_count]
  end

  def perform_with_details
    ensure_account_boundary!

    result = initial_result
    terminal_scope.find_each do |reminder|
      result[:skipped_touches] << skipped_touch_payload(reminder, skip_reason_for(reminder))
    end
    active_scope.find_each do |reminder|
      collect_result(result, reminder)
    end
    result[:cancellable_count] = result[:cancelled_count] + result[:failed_count]
    result[:remaining_open_count] = active_scope.count
    result[:skipped_count] = result[:skipped_touches].size

    result
  end

  private

  def initial_result
    {
      reason: reason,
      scope: scope_payload,
      found_count: scoped_reminders.count,
      cancellable_count: cancellable_scope.count,
      cancelled_count: 0,
      cancelled_touch_ids: [],
      skipped_count: 0,
      skipped_touches: [],
      failed_count: 0,
      failures: [],
      already_terminal_count: terminal_scope.count,
      remaining_open_count: nil
    }
  end

  def collect_result(result, reminder)
    original_status = reminder.status
    cancellation = cancel_reminder(reminder)
    if cancellation[:cancelled]
      result[:cancelled_count] += 1
      result[:cancelled_touch_ids] << reminder.id
    else
      result[:skipped_touches] << skipped_touch_payload(reminder, cancellation[:reason], status: cancellation[:status])
    end
  rescue StandardError => e
    result[:failed_count] += 1
    result[:failures] << skipped_touch_payload(reminder, e.message, status: original_status)
  end

  def cancellable_scope
    scoped_reminders.where(status: cancellable_status_values)
  end

  def active_scope
    scoped_reminders.where(status: active_status_values)
  end

  def terminal_scope
    scoped_reminders.where.not(status: active_status_values)
  end

  def scoped_reminders
    scope = scoped_remindable_reminders
    return scope if reminder_group.blank?

    scope.where(reminder_group: reminder_group)
  end

  def scoped_remindable_reminders
    base_scope = account.reminders
    return base_scope.where(remindable: remindable) unless remindable.is_a?(Conversation)

    base_scope.where(remindable: remindable).or(
      base_scope.where(remindable_type: nil, remindable_id: nil)
                .where('conversation_id = :conversation_id OR target_conversation_id = :conversation_id', conversation_id: remindable.id)
    )
  end

  def active_status_values
    status_values(ACTIVE_STATUSES)
  end

  def cancellable_status_values
    status_values(CANCELLABLE_STATUSES)
  end

  def status_values(statuses)
    Reminder.statuses.slice(*statuses).values
  end

  def cancel_reminder(reminder)
    reminder.with_lock do
      next { cancelled: false, status: reminder.status, reason: skip_reason_for(reminder) } unless cancellable_status?(reminder)

      reminder.update!(
        status: :cancelled,
        cancelled_at: Time.current,
        processing_started_at: nil,
        last_error: reason,
        metadata: reminder.metadata.to_h.merge(audit_metadata)
      )
      { cancelled: true }
    end
  end

  def cancellable_status?(reminder)
    CANCELLABLE_STATUSES.include?(reminder.status) && !reminder.delivery_materialized?
  end

  def skip_reason_for(reminder)
    return 'delivery_already_materialized' if reminder.delivery_materialized?
    return 'already_cancelled' if reminder.cancelled?
    return 'already_completed' if reminder.completed?
    return 'already_failed' if reminder.failed?

    'status_not_cancellable'
  end

  def skipped_touch_payload(reminder, reason, status: nil)
    {
      touch_id: reminder.id,
      status: status || reminder.status,
      reason: reason
    }
  end

  def scope_payload
    {
      account_id: account.id,
      remindable_type: remindable.class.name,
      remindable_id: remindable.id,
      reminder_group_id: reminder_group&.id
    }.compact
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
