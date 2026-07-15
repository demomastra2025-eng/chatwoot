class Telephony::RealtimeEventQueue
  MESSAGE_EVENTS = %w[message.created message.updated].freeze

  def self.telephony?(event_name, data)
    return true if event_name.to_s.start_with?('voice_call.')
    return false unless event_name.to_s.in?(MESSAGE_EVENTS)

    payload = data.respond_to?(:with_indifferent_access) ? data.with_indifferent_access : {}
    message = payload[:message]
    return message.content_type.to_s == 'voice_call' if message.respond_to?(:content_type)

    payload[:content_type].to_s == 'voice_call'
  end
end
