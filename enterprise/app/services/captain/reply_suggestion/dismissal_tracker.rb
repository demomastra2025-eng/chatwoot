# frozen_string_literal: true

require 'json'

# What the manager wrote instead of a dismissed suggestion. When a suggestion is dismissed, the dismissal is remembered for 30 minutes;
# the next outgoing message that the same user sends in that conversation within that time is recorded on the `dismissed` feedback
# event (payload.next_message_id), so that a later job can compare the suggestion with the answer the manager gave in its place.
#
# The hook is CaptainListener#message_created (an async listener): sending a message does not wait for it, and an outgoing message of
# a user costs one Redis read.
module Captain::ReplySuggestion::DismissalTracker
  FEEDBACK_EVENT_NAME = 'llm.copilot.feedback'
  TRACKED_STATUSES = %w[dismissed notice_dismissed cancelled].freeze
  MAX_PENDING = 5

  class << self
    def arm!(account_id:, user_id:, conversation_id:, suggestion_request_id:, now: Time.current)
      key = key_for(account_id, user_id, conversation_id)
      entries = live_entries(read_entries(key), now) + [{ 'suggestion_request_id' => suggestion_request_id, 'dismissed_at' => now.to_f }]
      Redis::Alfred.set(key, JSON.generate(entries.last(MAX_PENDING)), ex: Captain::ReplySuggestion::DISMISSAL_WINDOW_SECONDS)
    end

    # A message was created. Returns the number of dismissed suggestions it was recorded on.
    def message_created(message)
      return 0 unless manager_message?(message)

      key = key_for(message.account_id, message.sender_id, message.conversation_id)
      raw = Redis::Alfred.get(key)
      return 0 if raw.blank?
      # Two workers may see the same message: only the one that removes the key records it.
      return 0 unless Redis::Alfred.delete_if_value(key, raw).to_i == 1

      live_entries(parse(raw), message.created_at).count { |entry| record_next_message(message, entry) }
    end

    private

    # An outgoing public message of a user (not a customer, a note, or a bot).
    def manager_message?(message)
      message.outgoing? && !message.private? && message.sender_type == 'User' && message.sender_id.present?
    end

    def record_next_message(message, entry)
      event = dismissed_event(message.account_id, entry['suggestion_request_id'])
      return false if event.nil?

      delay = (message.created_at.to_f - entry['dismissed_at'].to_f).round
      event.update!(payload: event.payload.merge('next_message_id' => message.id, 'next_message_delay_seconds' => delay))
      true
    end

    def dismissed_event(account_id, suggestion_request_id)
      LlmEvent.where(account_id: account_id, event_name: FEEDBACK_EVENT_NAME, request_id: suggestion_request_id, status: TRACKED_STATUSES)
              .order(:id).last
    end

    # Only the dismissals that are at most 30 minutes older than the moment given, and not newer than it.
    def live_entries(entries, moment)
      window = Captain::ReplySuggestion::DISMISSAL_WINDOW_SECONDS
      entries.select { |entry| (0..window).cover?(moment.to_f - entry['dismissed_at'].to_f) }
    end

    def read_entries(key)
      parse(Redis::Alfred.get(key))
    end

    def parse(raw)
      parsed = raw.present? ? JSON.parse(raw) : []
      parsed.is_a?(Array) ? parsed : []
    rescue JSON::ParserError
      []
    end

    def key_for(account_id, user_id, conversation_id)
      "#{Captain::ReplySuggestion::RequestStore::PREFIX}:dismissed:#{account_id}:#{user_id}:#{conversation_id}"
    end
  end
end
