class TelegramPersonal::CallMessageBuilder
  CALL_TO_VOICE_STATUS = {
    'ringing' => 'ringing',
    'in_progress' => 'in-progress',
    'failed' => 'failed',
    'no_answer' => 'no-answer',
    'completed' => 'completed'
  }.freeze

  def self.create!(conversation:, call:, user: nil)
    new(conversation: conversation, call: call, user: user).create!
  end

  def self.update_status!(call:, status: nil, agent: nil, duration_seconds: nil)
    new(conversation: call.conversation, call: call).update_status!(
      status: status, agent: agent, duration_seconds: duration_seconds
    )
  end

  def self.update_recording_url!(call:)
    message = call.message
    return unless message

    data = (message.content_attributes || {}).dup
    data['data'] ||= {}
    data['data']['recording_url'] = call.recording_url
    message.update!(content_attributes: data)
  end

  def self.update_call_sid!(call:, call_sid:)
    message = call.message
    return unless message

    attrs = (message.content_attributes || {}).dup
    attrs['data'] ||= {}
    attrs['data']['call_sid'] = call_sid
    message.update!(source_id: "tg_call_#{call_sid}", content_attributes: attrs)
  end

  def initialize(conversation:, call:, user: nil)
    @conversation = conversation
    @call = call
    @user = user
  end

  def create!
    params = {
      content: 'Telegram Call',
      message_type: message_type,
      content_type: 'voice_call',
      content_attributes: { 'data' => build_data_payload }
    }
    params[:source_id] = "tg_call_#{call.provider_call_id}" if call.outgoing?

    Messages::MessageBuilder.new(
      sender,
      conversation,
      params,
      skip_send_reply: true,
      skip_delivery_policy: true
    ).perform
  end

  def update_status!(status:, agent: nil, duration_seconds: nil)
    message = call.message
    return unless message

    data = (message.content_attributes || {}).dup
    data['data'] ||= {}
    data['data']['status'] = map_status(status) if status
    data['data']['accepted_by'] = { 'id' => agent.id, 'name' => agent.name } if agent
    data['data']['duration_seconds'] = duration_seconds unless duration_seconds.nil?

    message.update!(content_attributes: data)
    message
  end

  private

  attr_reader :conversation, :call, :user

  def build_data_payload
    {
      'call_sid' => call.provider_call_id,
      'status' => map_status(call.status),
      'call_direction' => call.direction_label,
      'call_source' => 'telegram_personal',
      'call_id' => call.id,
      'from_number' => from_number,
      'to_number' => to_number,
      'meta' => { 'created_at' => Time.zone.now.to_i }
    }
  end

  def message_type
    call.outgoing? ? 'outgoing' : 'incoming'
  end

  def sender
    return user if call.outgoing? && user

    conversation.contact
  end

  def from_number
    call.incoming? ? contact_identifier : channel_identifier
  end

  def to_number
    call.incoming? ? channel_identifier : contact_identifier
  end

  def channel_identifier
    conversation.inbox.channel&.phone_number
  end

  def contact_identifier
    contact = conversation.contact
    return contact.phone_number if contact&.phone_number.present?

    username = conversation.additional_attributes&.dig('username').presence ||
               contact&.additional_attributes&.dig('social_telegram_user_name').presence
    return "@#{username.to_s.delete_prefix('@')}" if username.present?

    contact&.name
  end

  def map_status(status)
    CALL_TO_VOICE_STATUS[status] || status
  end
end
