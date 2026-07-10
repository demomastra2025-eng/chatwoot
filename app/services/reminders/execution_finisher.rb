class Reminders::ExecutionFinisher
  def self.materialized_message_for(reminder)
    message_id = reminder.metadata.to_h[Reminder::DELIVERY_MATERIALIZED_MESSAGE_ID_KEY]
    message = Message.outgoing.find_by(id: message_id, account_id: reminder.account_id)
    return if message.blank?
    return unless message.additional_attributes.to_h['touch_id'].to_s == reminder.id.to_s

    message
  end

  attr_reader :reminder, :processing_claim

  def initialize(reminder:, processing_claim:)
    @reminder = reminder
    @processing_claim = processing_claim
  end

  def perform(message = nil)
    message ||= materialized_message
    if reminder.delivery_materialized? && message.blank?
      raise ActiveRecord::RecordNotFound, "Materialized message for touch ##{reminder.id} is missing"
    end

    enqueue_delivery(message) if message.present?
    message = complete_execution(message)
    return reminder if message.blank?

    schedule_next_occurrence
    message
  end

  private

  def enqueue_delivery(message)
    job = Reminders::DeliverMaterializedMessageJob
    arguments = [reminder.id, message.id, processing_claim]
    return job.set(wait: 2.seconds).perform_later(*arguments) if message.attachments.exists?

    job.perform_later(*arguments)
  end

  def complete_execution(message)
    return if message.blank?
    return complete_unsaved!(message) unless reminder.persisted?

    completed = false
    reminder.with_lock do
      reminder.reload
      next unless current_execution?
      next unless materialized_message_id == message.id.to_s

      reminder.complete!
      completed = true
    end
    completed ? message : nil
  end

  def complete_unsaved!(message)
    reminder.complete!
    message
  end

  def current_execution?
    reminder.processing? && reminder.processing_claim_token == processing_claim
  end

  def materialized_message
    self.class.materialized_message_for(reminder)
  end

  def materialized_message_id
    reminder.metadata.to_h[Reminder::DELIVERY_MATERIALIZED_MESSAGE_ID_KEY].to_s
  end

  def schedule_next_occurrence
    Reminders::RecurrenceService.new(reminder: reminder).schedule_next!
  rescue StandardError => e
    ChatwootExceptionTracker.new(e, account: reminder.account).capture_exception
    Rails.logger.error("[Touches] Failed to schedule next recurring touch for ##{reminder.id}: #{e.message}")
  end
end
