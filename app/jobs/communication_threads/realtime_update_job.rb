# frozen_string_literal: true

class CommunicationThreads::RealtimeUpdateJob < ApplicationJob
  queue_as :communication_thread_realtime
  retry_on ActiveRecord::RecordNotFound, ActiveRecord::RecordInvalid, wait: 2.seconds, attempts: 3

  def perform(communication_thread_id:, source_conversation_id:, source_event:, **options)
    arguments = {
      communication_thread_id: communication_thread_id,
      source_conversation_id: source_conversation_id,
      source_event: source_event,
      message_id: options[:message_id],
      performer_id: options[:performer_id]
    }
    recipient_user_ids = options[:recipient_user_ids]
    arguments[:recipient_user_ids] = recipient_user_ids if recipient_user_ids.present?

    CommunicationThreads::RealtimeUpdateService.new(**arguments).perform
  end
end
