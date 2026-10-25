# frozen_string_literal: true

# The mark a message the manager wrote by hand leaves in the conversation and in the person's thread (see StickyAgent): the time of
# the newest such message. Every sticky value written before it no longer leads the dialog. Resolving a conversation sets the same
# mark in that conversation alone (#mark_resolved!).
module Captain::ReplySuggestion::StickyAgent::ManualReply
  KIND = 'manual_reply'

  class << self
    # The manager wrote this message by hand (CaptainListener#message_created): the sticky values written before it no longer lead
    # the dialog of the conversation and of the person's thread. Returns true when the message is such a message.
    def mark!(message)
      return false unless manual?(message)

      at = message.created_at.to_f
      value = JSON.generate({ 'at' => at, 'message_id' => message.id })
      keys(message.conversation).each do |key|
        Redis::Alfred.set(key, value, ex: Captain::ReplySuggestion::StickyAgent::CONFIRMED_TTL_SECONDS) if marked_at(Redis::Alfred.get(key)).to_f < at
      end
      true
    rescue StandardError => e
      Rails.logger.warn("[CAPTAIN][ReplySuggestion] manual reply not marked error_class=#{e.class.name}")
      false
    end

    # The conversation was resolved (StickyAgent.clear!): the values written before now no longer lead its dialog. Only the mark of
    # the conversation is set; the person's thread keeps its own, which the person's other conversations read.
    def mark_resolved!(conversation)
      value = JSON.generate({ 'at' => Time.current.to_f, 'resolved' => true })
      Captain::ReplySuggestion::StickyAgent.keys_for(conversation, kinds: [KIND], thread: false).each do |key|
        Redis::Alfred.set(key, value, ex: Captain::ReplySuggestion::StickyAgent::CONFIRMED_TTL_SECONDS)
      end
    end

    def keys(conversation)
      Captain::ReplySuggestion::StickyAgent.keys_for(conversation, kinds: [KIND])
    end

    # The time of the newest mark among the raw values of #keys (0 without one).
    def latest(raws)
      raws.filter_map { |raw| marked_at(raw) }.max.to_f
    end

    private

    def marked_at(raw)
      return if raw.blank?

      entry = JSON.parse(raw)
      entry['at'].to_f if entry.is_a?(Hash) && entry['at'].to_f.positive?
    rescue JSON::ParserError
      nil
    end

    # An outgoing public message of a user (not a customer, a note, a bot or the AI) that is not the text of a used suggestion
    # (the reply box marks a sent suggestion: content_attributes.copilot.assisted).
    def manual?(message)
      return false unless message&.outgoing? && !message.private? && message.sender_type == 'User' && message.sender_id.present?

      message.content_attributes.to_h.with_indifferent_access.dig(:copilot, :assisted) != true
    end
  end
end
