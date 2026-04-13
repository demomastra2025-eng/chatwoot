class WhatsappWeb::CallEventService
  STATUS_MAP = {
    'offer' => 'ringing',
    'ringing' => 'ringing',
    'accept' => 'in-progress',
    'connected' => 'in-progress',
    'ongoing' => 'in-progress',
    'active' => 'in-progress',
    'reject' => 'no-answer',
    'decline' => 'no-answer',
    'timeout' => 'no-answer',
    'busy' => 'no-answer',
    'completed' => 'completed',
    'complete' => 'completed',
    'ended' => 'completed',
    'end' => 'completed',
    'hangup' => 'completed',
    'terminate' => 'completed',
    'terminated' => 'completed',
    'failed' => 'failed',
    'error' => 'failed',
    'cancelled' => 'failed',
    'canceled' => 'failed'
  }.freeze
  TERMINAL_STATUSES = %w[completed no-answer failed].freeze

  pattr_initialize [:channel!, :payload!]

  def perform
    return if call_id.blank? || remote_jid.blank? || normalized_status.blank?
    return if group_call?
    return if channel.ignored_remote_jid?(remote_jid)

    contact_inbox = WhatsappWeb::ContactSyncService.new(
      channel: channel,
      contact_payload: {
        remoteJid: remote_jid,
        remoteJidAlt: payload[:chatId],
        remoteLid: payload[:from],
        pushName: payload[:name] || payload[:notify] || payload[:pushName]
      }
    ).perform
    return if contact_inbox.blank?

    conversation = WhatsappWeb::ConversationSyncService.new(
      channel: channel,
      contact_inbox: contact_inbox,
      activity_at: event_time
    ).perform

    sync_conversation!(conversation)
    sync_message!(conversation)
    conversation
  end

  private

  def sync_conversation!(conversation)
    attrs = (conversation.additional_attributes || {}).deep_dup
    attrs['call_status'] = normalized_status
    attrs['call_direction'] = call_direction
    attrs['call_provider'] = 'whatsapp_web'
    attrs['call_source_id'] ||= call_id
    attrs['meta'] ||= {}
    attrs['meta']['initiated_at'] ||= event_timestamp

    if normalized_status == 'in-progress'
      attrs['call_started_at'] ||= event_timestamp
      attrs['meta']['started_at'] ||= event_timestamp
    elsif TERMINAL_STATUSES.include?(normalized_status)
      attrs['call_ended_at'] = event_timestamp
      attrs['call_duration'] = resolved_duration(attrs)
      attrs['meta']['ended_at'] = event_timestamp
    end

    updates = { additional_attributes: attrs }
    updates[:last_activity_at] = [conversation.last_activity_at, event_time].compact.max if event_time.present?

    conversation.update!(updates)
  end

  def sync_message!(conversation)
    message = conversation.messages.voice_calls.find_by(source_id: call_id)
    message ? update_message!(message) : create_message!(conversation)
  end

  def create_message!(conversation)
    conversation.messages.create!(
      account_id: conversation.account_id,
      inbox_id: conversation.inbox_id,
      message_type: message_type,
      sender: message_sender(conversation),
      content: 'WhatsApp Call',
      content_type: :voice_call,
      source_id: call_id,
      content_attributes: {
        data: call_payload
      }
    )
  end

  def update_message!(message)
    merged_data = (message.content_attributes || {}).deep_dup
    merged_data['data'] = (merged_data['data'] || {}).merge(call_payload) do |key, old_value, new_value|
      if key == 'meta'
        old_value.to_h.merge(new_value.to_h) do |meta_key, old_meta_value, new_meta_value|
          %w[created_at ringing_at started_at].include?(meta_key) ? old_meta_value : new_meta_value
        end
      else
        new_value
      end
    end

    updates = { content_attributes: merged_data }
    unless explicit_outgoing?
      updates[:message_type] = :incoming if message.message_type != 'incoming'
      updates[:sender] = message.conversation.contact if message.sender != message.conversation.contact
    end

    message.update!(updates)
  end

  def call_payload
    {
      'call_sid' => call_id,
      'status' => normalized_status,
      'call_direction' => call_direction,
      'provider' => 'whatsapp_web',
      'inbox_id' => channel.inbox.id,
      'remote_jid' => remote_jid,
      'is_video' => video_call?,
      'meta' => call_meta
    }.compact
  end

  def call_meta
    meta = {
      'created_at' => event_timestamp,
      'ringing_at' => event_timestamp
    }
    meta['started_at'] = event_timestamp if normalized_status == 'in-progress'
    meta['ended_at'] = event_timestamp if TERMINAL_STATUSES.include?(normalized_status)
    meta['duration'] = duration if duration.present?
    meta.compact
  end

  def call_id
    @call_id ||= payload[:id].to_s.presence
  end

  def remote_jid
    @remote_jid ||= WhatsappWeb::ProviderPayloadNormalizer.canonical_remote_jid(
      payload[:from],
      payload[:chatId],
      payload[:remoteJid],
      payload[:remoteJidAlt],
      payload[:remoteLid]
    ).to_s.presence
  end

  def normalized_status
    @normalized_status ||= STATUS_MAP[payload[:status].to_s.downcase]
  end

  def group_call?
    ActiveModel::Type::Boolean.new.cast(payload[:isGroup]) || remote_jid.to_s.end_with?('@g.us')
  end

  def video_call?
    ActiveModel::Type::Boolean.new.cast(payload[:isVideo])
  end

  def explicit_outgoing?
    ActiveModel::Type::Boolean.new.cast(payload[:fromMe]) ||
      ActiveModel::Type::Boolean.new.cast(payload[:outgoing]) ||
      ActiveModel::Type::Boolean.new.cast(payload[:isOutgoing]) ||
      payload[:direction].to_s == 'outgoing'
  end

  def call_direction
    explicit_outgoing? ? 'outbound' : 'inbound'
  end

  def message_type
    explicit_outgoing? ? :outgoing : :incoming
  end

  def message_sender(conversation)
    explicit_outgoing? ? nil : conversation.contact
  end

  def duration
    value = payload[:duration] || payload[:callDuration] || payload[:durationSeconds]
    return if value.blank?

    value.to_i
  end

  def event_time
    @event_time ||= begin
      candidates = [
        payload[:timestamp],
        payload[:t],
        payload[:date],
        payload[:eventTime],
        payload[:messageTimestamp]
      ]

      candidates.each do |value|
        parsed = parse_time(value)
        return parsed if parsed.present?
      end

      Time.current
    end
  end

  def event_timestamp
    @event_timestamp ||= event_time.to_i
  end

  def parse_time(value)
    return if value.blank?

    if value.is_a?(Numeric) || value.to_s.match?(/\A\d+\z/)
      number = value.to_i
      number = number / 1000 if number > 9_999_999_999
      return Time.zone.at(number)
    end

    Time.zone.parse(value.to_s)
  rescue ArgumentError, TypeError
    nil
  end

  def resolved_duration(attrs)
    return duration if duration.present?

    started_at = attrs['call_started_at']
    return if started_at.blank?

    [event_timestamp - started_at.to_i, 0].max
  end
end
