class Voice::CallStatus::Manager
  pattr_initialize [:conversation!, :call_sid]

  ALLOWED_STATUSES = Telephony::CallSession::ALLOWED_STATUSES.freeze
  TERMINAL_STATUSES = Telephony::CallSession::TERMINAL_STATUSES.freeze

  def process_status_update(raw_status, duration: nil, timestamp: nil)
    status = Telephony::CallSession.normalize_status(raw_status)
    return unless status

    current_status = Telephony::CallSession.normalize_status(conversation.additional_attributes&.dig('call_status'))
    return if current_status == status && status_attributes_current?(status, duration: duration, timestamp: timestamp)

    apply_status(status, duration: duration, timestamp: timestamp)
    update_message(status)
  end

  private

  def status_attributes_current?(status, duration:, timestamp:)
    attrs = conversation.additional_attributes || {}

    if status == 'in_progress'
      return true if timestamp.nil?

      return attrs['call_started_at'].to_i == timestamp.to_i
    end

    if TERMINAL_STATUSES.include?(status)
      ended_at_current = timestamp.nil? || attrs['call_ended_at'].to_i == timestamp.to_i
      duration_current = duration.nil? || attrs['call_duration'].to_i == duration.to_i
      return ended_at_current && duration_current
    end

    true
  end

  def apply_status(status, duration:, timestamp:)
    attrs = (conversation.additional_attributes || {}).dup
    attrs['call_status'] = status

    if status == 'in_progress'
      attrs['call_started_at'] ||= timestamp || now_seconds
    elsif TERMINAL_STATUSES.include?(status)
      attrs['call_ended_at'] = timestamp || now_seconds
      attrs['call_duration'] = resolved_duration(attrs, duration, timestamp)
    end

    conversation.update!(
      additional_attributes: attrs,
      last_activity_at: current_time
    )
  end

  def resolved_duration(attrs, provided_duration, timestamp)
    return provided_duration if provided_duration

    started_at = attrs['call_started_at']
    return unless started_at && timestamp

    [timestamp - started_at.to_i, 0].max
  end

  def update_message(status)
    message = voice_message_for_call
    return unless message

    data = normalized_content_attributes(message)
    data['data'] ||= {}
    data['data']['status'] = status

    message.update!(content_attributes: data)
  end

  def voice_message_for_call
    return if call_sid.blank?

    source_id = "voice_call:#{call_sid}"
    voice_messages = conversation.messages.where(content_type: 'voice_call')
    voice_messages.find_by(source_id: source_id) ||
      voice_messages.order(created_at: :desc, id: :desc).detect { |message| voice_message_call_sid(message) == call_sid }
  end

  def voice_message_call_sid(message)
    data = normalized_content_attributes(message)['data']
    return unless data.is_a?(Hash)

    data['call_sid'] || data[:call_sid] || data['callSid'] || data[:callSid]
  end

  def normalized_content_attributes(message)
    raw_attributes = message&.content_attributes
    attributes = if raw_attributes.is_a?(String)
                   JSON.parse(raw_attributes)
                 elsif raw_attributes.respond_to?(:to_h)
                   raw_attributes.to_h
                 else
                   {}
                 end

    return {} unless attributes.is_a?(Hash)

    attributes.deep_dup.deep_stringify_keys
  rescue JSON::ParserError
    {}
  end

  def now_seconds
    current_time.to_i
  end

  def current_time
    @current_time ||= Time.zone.now
  end
end
