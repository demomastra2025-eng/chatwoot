class Voice::CallMessageBuilder
  def self.perform!(conversation:, direction:, payload:, user: nil, timestamps: {})
    new(
      conversation: conversation,
      direction: direction,
      payload: payload,
      user: user,
      timestamps: timestamps
    ).perform!
  end

  def initialize(conversation:, direction:, payload:, user:, timestamps:)
    @conversation = conversation
    @direction = direction
    @payload = payload
    @user = user
    @timestamps = timestamps
  end

  def perform!
    validate_sender!
    message = latest_message
    message ? update_message!(message) : create_message!
  end

  private

  attr_reader :conversation, :direction, :payload, :user, :timestamps

  def latest_message
    exact_message || fallback_legacy_message
  end

  def exact_message
    return if call_sid.blank?

    voice_messages = conversation.messages.voice_calls
    voice_messages.find_by(source_id: source_id) ||
      voice_messages.order(created_at: :desc, id: :desc).detect { |message| message_call_sid(message) == call_sid }
  end

  def fallback_legacy_message
    return if call_sid.present?

    conversation.messages.voice_calls.order(created_at: :desc).first
  end

  def update_message!(message)
    message.update!(
      message_type: message_type,
      content_attributes: { 'data' => base_payload },
      sender: sender
    )
  end

  def create_message!
    params = {
      content: 'Voice Call',
      message_type: message_type,
      content_type: 'voice_call',
      source_id: source_id,
      content_attributes: { 'data' => base_payload }
    }
    return Messages::MessageBuilder.new(sender, conversation, params).perform unless direction == 'outbound'

    message = conversation.messages.build(
      params.merge(
        account: conversation.account,
        inbox: conversation.inbox,
        sender: sender
      )
    )
    message.skip_send_reply = true
    message.save!
    message
  end

  def base_payload
    @base_payload ||= begin
      data = payload.slice(
        :call_sid,
        :provider_request_ref,
        :status,
        :call_direction,
        :conference_sid,
        :from_number,
        :to_number
      ).stringify_keys
      data['call_direction'] = direction
      data['meta'] = {
        'created_at' => timestamps[:created_at] || current_timestamp,
        'ringing_at' => timestamps[:ringing_at] || current_timestamp
      }.compact
      data
    end
  end

  def message_type
    direction == 'outbound' ? 'outgoing' : 'incoming'
  end

  def source_id
    return if call_sid.blank?

    "voice_call:#{call_sid}"
  end

  def call_sid
    payload[:call_sid].presence || payload['call_sid'].presence
  end

  def message_call_sid(message)
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

    attributes.is_a?(Hash) ? attributes.deep_stringify_keys : {}
  rescue JSON::ParserError
    {}
  end

  def sender
    return user if direction == 'outbound'

    conversation.contact
  end

  def validate_sender!
    return unless direction == 'outbound'

    raise ArgumentError, 'Agent sender required for outbound calls' unless user
  end

  def current_timestamp
    @current_timestamp ||= Time.zone.now.to_i
  end
end
