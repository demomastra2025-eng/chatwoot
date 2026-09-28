class Captain::Conversation::ReplayKnownDeliveryReceiptsJob < ApplicationJob
  queue_as :scheduled_jobs

  BATCH_SIZE = 100
  GRACE_PERIOD = 1.minute
  CANDIDATE_SQL = <<~SQL.squish.freeze
    ((messages.additional_attributes ->> 'captain_delivery_state' = 'dispatching' AND messages.source_id IS NOT NULL)
     OR (messages.additional_attributes ->> 'captain_delivery_state' = 'submitted'
         AND messages.additional_attributes -> 'captain_delivery_pending_ack' ->> 'status' = 'delivered')
     OR (messages.additional_attributes ->> 'captain_delivery_state' = 'provider_failed'
         AND messages.additional_attributes -> 'captain_delivery_pending_ack' ->> 'status' = 'failed'))
  SQL
  REMINDER_CANDIDATE_SQL = <<~SQL.squish.freeze
    reminders.status IN (2, 3) AND
    reminders.metadata ->> 'processing_claim_token' IS NOT NULL AND
    reminders.metadata ->> 'delivery_materialized_message_id' IS NOT NULL AND
    (reminders.metadata ->> 'delivery_dispatched_message_id') IS DISTINCT FROM
      (reminders.metadata ->> 'delivery_materialized_message_id')
  SQL

  def perform
    @enqueued_message_ids = Set.new
    cursor = Captain::DeliveryReceiptReplayCursor.create_or_find_by!(id: 1)
    cursor.with_lock do
      scan_stream(cursor, :last_message_id, :message_high_water_id, candidates) { |scope| scan_candidates(cursor, scope) }
      scan_stream(cursor, :last_reminder_id, :reminder_high_water_id, reminders) { |scope| scan_reminders(cursor, scope) }
      cursor.save! if cursor.changed?
    end
  end

  private

  def scan_stream(cursor, last_key, high_key, scope)
    high_water = cursor.public_send(high_key)
    if high_water.zero?
      high_water = scope.reorder(id: :desc).pick(:id).to_i
      cursor.public_send("#{high_key}=", high_water)
    end
    return if high_water.zero?

    table = scope.klass.table_name
    scanned = yield(scope.where("#{table}.id > ? AND #{table}.id <= ?", cursor.public_send(last_key), high_water))
    return if scanned == BATCH_SIZE && cursor.public_send(last_key) < high_water

    # A fixed high-water ends the cycle even when newer rows arrive every minute.
    # The next sweep revisits late receipts below the old cursor.
    cursor.public_send("#{last_key}=", 0)
    cursor.public_send("#{high_key}=", 0)
  end

  def scan_candidates(cursor, scope)
    scope.each do |message|
      message.reload
      # Redis can lose the original job after a committed receipt. The fence
      # replays only a proven receipt/ack, never the ambiguous provider POST.
      enqueue_receipt(message) if replayable?(message)
      cursor.last_message_id = message.id
    end.size
  end

  def scan_reminders(cursor, scope)
    scope.each do |reminder|
      message = Message.outgoing.find_by(id: reminder.metadata.to_h['delivery_materialized_message_id'], account_id: reminder.account_id)
      enqueue_receipt(message, reminder: reminder) if message && reminder_receipt?(message, reminder)
      cursor.last_reminder_id = reminder.id
    end.size
  end

  def enqueue_receipt(message, reminder: outstanding_reminder_for(message))
    return if @enqueued_message_ids.include?(message.id)

    job = if reminder
            Captain::Conversation::RecoverKnownDeliveryReceiptJob.perform_later(message.id, reminder.id, reminder.processing_claim_token)
          else
            SendReplyJob.perform_later(message.id)
          end
    raise(job&.enqueue_error || ActiveJob::EnqueueError.new('Captain receipt replay was not enqueued')) unless job&.successfully_enqueued?

    @enqueued_message_ids.add(message.id)
  end

  def outstanding_reminder_for(message)
    touch_id = message.additional_attributes.to_h['touch_id']
    return if touch_id.blank?

    reminder = Reminder.find_by(id: touch_id, account_id: message.account_id)
    reminder if reminder && reminder_receipt?(message, reminder)
  end

  def reminder_receipt?(message, reminder)
    return false unless captain_delivery_message?(message, reminder) && open_materialized_reminder?(message, reminder)

    state = message.additional_attributes.to_h['captain_delivery_state']
    return true if state == 'submitted'
    return true if replayable?(message)

    state == 'outcome_unknown' && message.inbox.channel_type == 'Channel::Tiktok' && message.source_id.present?
  end

  def captain_delivery_message?(message, reminder)
    message.sender_type == 'Captain::Assistant' && !message.private? &&
      %w[Channel::Line Channel::Tiktok].include?(message.inbox.channel_type) &&
      message.additional_attributes.to_h['touch_id'].to_s == reminder.id.to_s
  end

  def open_materialized_reminder?(message, reminder)
    reminder.delivery_materialized_for?(message.id) && !reminder.delivery_dispatched_for?(message.id) &&
      reminder.processing_claim_token.present? && (reminder.processing? || reminder.completed?)
  end

  def candidates
    Message.joins(:inbox).where(sender_type: 'Captain::Assistant', message_type: Message.message_types[:outgoing], private: false)
           .where(inboxes: { channel_type: %w[Channel::Line Channel::Tiktok] })
           .where(CANDIDATE_SQL)
           .where("inboxes.channel_type = 'Channel::Tiktok' OR messages.additional_attributes ->> 'captain_delivery_state' <> 'dispatching'")
           .where('messages.updated_at <= ?', GRACE_PERIOD.ago)
           .reorder(:id).limit(BATCH_SIZE)
  end

  def reminders
    Reminder.where(REMINDER_CANDIDATE_SQL)
            .where('reminders.updated_at <= ?', GRACE_PERIOD.ago)
            .reorder(:id).limit(BATCH_SIZE)
  end

  def replayable?(message)
    return false if message.updated_at > GRACE_PERIOD.ago

    attributes = message.additional_attributes.to_h
    state = attributes['captain_delivery_state']
    return message.inbox.channel_type == 'Channel::Tiktok' && message.source_id.present? if state == 'dispatching'

    ack_status = attributes['captain_delivery_pending_ack'].to_h['status']
    (state == 'submitted' && ack_status == 'delivered') || (state == 'provider_failed' && ack_status == 'failed')
  end
end
