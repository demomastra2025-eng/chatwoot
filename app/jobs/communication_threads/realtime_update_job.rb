# frozen_string_literal: true

class CommunicationThreads::RealtimeUpdateJob < ApplicationJob
  queue_as :communication_thread_realtime
  retry_on ActiveRecord::RecordNotFound, ActiveRecord::RecordInvalid, wait: 2.seconds, attempts: 3

  def perform(communication_thread_id:, source_conversation_id:, source_event:, message_id: nil, performer_id: nil)
    CommunicationThreads::RealtimeUpdateService.new(
      communication_thread_id: communication_thread_id,
      source_conversation_id: source_conversation_id,
      source_event: source_event,
      message_id: message_id,
      performer_id: performer_id
    ).perform
  end
end
