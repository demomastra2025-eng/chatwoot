class Voice::CallStatus::Manager
  pattr_initialize [:conversation!, :call_sid]

  ALLOWED_STATUSES = Telephony::CallSession::ALLOWED_STATUSES.freeze
  TERMINAL_STATUSES = Telephony::CallSession::TERMINAL_STATUSES.freeze

  def process_status_update(raw_status, duration: nil, timestamp: nil)
    status = Telephony::CallSession.normalize_status(raw_status)
    return unless status

    current_status = Telephony::CallSession.normalize_status(conversation.additional_attributes&.dig('call_status'))
    return if current_status == status

    apply_status(status, duration: duration, timestamp: timestamp)
    update_message(status)
  end

  private

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
    message = conversation.messages
                          .where(content_type: 'voice_call')
                          .order(created_at: :desc)
                          .first
    return unless message

    data = (message.content_attributes || {}).dup
    data['data'] ||= {}
    data['data']['status'] = status

    message.update!(content_attributes: data)
  end

  def now_seconds
    current_time.to_i
  end

  def current_time
    @current_time ||= Time.zone.now
  end
end
