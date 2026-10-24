# frozen_string_literal: true

# Decides which of the open or pending conversations of one communication thread stays open. It reads and never writes,
# so the one-off cleanup can print the same decision as a dry run.
#
# The conversation with the latest activity stays. A voice conversation that is only slightly newer than a messaging
# conversation (a missed call right after a chat) does not win: the person is reached in the messenger, the call stays in
# the thread. A call that is live right now is never closed, and nothing is decided while it lasts.
class CommunicationThreads::SingleOpenDialogPlanner
  OPEN_STATUSES = %w[open pending].freeze
  VOICE_CHANNEL_TYPE = 'Channel::Voice'
  # A messaging conversation whose last activity is at most this long before the latest voice activity still wins.
  MESSAGING_PREFERENCE_WINDOW = 30.minutes
  # A call that was not updated for this long is treated as finished: a lost "call ended" event must not freeze a thread.
  LIVE_CALL_STALE_AFTER = 3.hours
  LIVE_CALL_STATUSES = (Telephony::CallSession::CANONICAL_STATUSES - Telephony::CallSession::TERMINAL_STATUSES).freeze

  # closed is empty when nothing has to change; deferred is :live_call when a call is going on in one of the conversations.
  Plan = Struct.new(:thread, :kept, :closed, :deferred, keyword_init: true)

  def self.voice?(conversation)
    conversation.inbox&.channel_type == VOICE_CHANNEL_TYPE
  end

  def initialize(thread:, conversations:, preferred_conversation_id: nil)
    @thread = thread
    @conversations = conversations
    @preferred_conversation_id = preferred_conversation_id
  end

  def perform
    return if @conversations.size < 2
    return Plan.new(thread: @thread, kept: nil, closed: [], deferred: :live_call) if @conversations.any? { |c| live_call?(c) }

    kept = preferred_conversation || messenger_close_to_latest_call || latest_conversation
    Plan.new(thread: @thread, kept: kept, closed: @conversations - [kept])
  end

  private

  def preferred_conversation
    @conversations.find { |conversation| conversation.id == @preferred_conversation_id }
  end

  def latest_conversation
    @latest_conversation ||= @conversations.max_by { |conversation| activity_key(conversation) }
  end

  # The newest messenger conversation that is at most MESSAGING_PREFERENCE_WINDOW older than the call that is the latest.
  def messenger_close_to_latest_call
    return unless self.class.voice?(latest_conversation)

    @conversations.reject { |conversation| self.class.voice?(conversation) }
                  .select { |conversation| close_to_latest?(conversation) }
                  .max_by { |conversation| activity_key(conversation) }
  end

  def close_to_latest?(conversation)
    (latest_conversation.last_activity_at - conversation.last_activity_at) <= MESSAGING_PREFERENCE_WINDOW.to_i
  end

  def activity_key(conversation)
    [conversation.last_activity_at.to_f, conversation.id]
  end

  def live_call?(conversation)
    fresh_after = LIVE_CALL_STALE_AFTER.ago
    status = Telephony::CallSession.normalize_status(conversation.additional_attributes.to_h['call_status'])
    return true if LIVE_CALL_STATUSES.include?(status) && [conversation.updated_at, conversation.last_activity_at].max > fresh_after

    Telephony::CallSession.active.where(conversation_id: conversation.id).exists?(['telephony_call_sessions.updated_at > ?', fresh_after])
  end
end
