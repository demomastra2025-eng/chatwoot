# frozen_string_literal: true

class CommunicationThreads::RealtimeUpdateJob < ApplicationJob
  queue_as :communication_thread_realtime
  retry_on ActiveRecord::RecordNotFound, ActiveRecord::RecordInvalid, wait: 2.seconds, attempts: 3

  COALESCE_TTL_SECONDS = 10

  def self.coalesce_seq_key(communication_thread_id, source_conversation_id, source_event)
    "comm_thread_rt:seq:#{communication_thread_id}:#{source_conversation_id}:#{source_event}"
  end

  def self.coalesce_done_key(communication_thread_id, source_conversation_id, source_event)
    "comm_thread_rt:done:#{communication_thread_id}:#{source_conversation_id}:#{source_event}"
  end

  def perform(communication_thread_id:, source_conversation_id:, source_event:, message_id: nil, performer_id: nil)
    return if message_id.nil? && coalesced_burst_already_rendered?(communication_thread_id, source_conversation_id, source_event)

    CommunicationThreads::RealtimeUpdateService.new(
      communication_thread_id: communication_thread_id,
      source_conversation_id: source_conversation_id,
      source_event: source_event,
      message_id: message_id,
      performer_id: performer_id
    ).perform
  end

  private

  def coalesced_burst_already_rendered?(communication_thread_id, source_conversation_id, source_event)
    seq_key = self.class.coalesce_seq_key(communication_thread_id, source_conversation_id, source_event)
    done_key = self.class.coalesce_done_key(communication_thread_id, source_conversation_id, source_event)
    current_seq = Redis::Alfred.get(seq_key).to_i
    return false if current_seq <= 0

    done_seq = Redis::Alfred.get(done_key).to_i
    return true if done_seq >= current_seq

    Redis::Alfred.setex(done_key, current_seq.to_s, COALESCE_TTL_SECONDS)
    false
  end
end
