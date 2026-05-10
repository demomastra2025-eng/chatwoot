class LlmFormatter::ConversationLlmFormatter < LlmFormatter::DefaultLlmFormatter
  def format(config = {})
    sections = []
    sections << "Conversation ID: ##{@record.display_id}"
    sections << "Channel: #{@record.inbox.channel.name}"
    sections << 'Message History:'
    sections << if @record.messages.any?
                  build_messages(config)
                else
                  'No messages in this conversation'
                end

    append_section(sections, 'Voice Call Transcripts:', build_voice_transcripts)

    sections << "Contact Details: #{@record.contact.to_llm_text}" if config[:include_contact_details]

    attributes = build_attributes
    if attributes.present?
      sections << 'Conversation Attributes:'
      sections << attributes
    end

    sections.join("\n")
  end

  private

  def build_messages(config = {})
    return "No messages in this conversation\n" if @record.messages.empty?

    messages = @record.messages.where.not(message_type: [:activity, :template]).where.not(content_type: :voice_call)
    return "No messages in this conversation\n" unless messages.exists?

    if config[:token_limit]
      build_limited_messages(messages, config)
    else
      build_all_messages(messages, config)
    end
  end

  def append_section(sections, title, body)
    return if body.blank?

    sections << title
    sections << body
  end

  def build_all_messages(messages, config)
    message_text = ''
    messages.order(created_at: :asc).each do |message|
      # Skip private messages unless explicitly included in config
      next if message.private? && !config[:include_private_messages]

      message_text << format_message(message)
    end
    message_text
  end

  def build_limited_messages(messages, config)
    selected = []
    character_count = 0

    messages.reorder(created_at: :desc).each do |message|
      # Skip private messages unless explicitly included in config
      next if message.private? && !config[:include_private_messages]

      formatted = format_message(message)
      break if character_count + formatted.length > config[:token_limit]

      selected.prepend(formatted)
      character_count += formatted.length
    end

    selected.join
  end

  def format_message(message)
    sender = case message.sender_type
             when 'User'
               'Support Agent'
             when 'Contact'
               'User'
             else
               'Bot'
             end
    sender = "[Private Note] #{sender}" if message.private?
    "#{sender}: #{message.content_for_llm}\n"
  end

  def build_voice_transcripts
    seen_call_refs = []
    sections = @record.messages.voice_calls.order(created_at: :asc).filter_map do |message|
      data = message.content_attributes.to_h['data'] || {}
      lines = voice_transcript_lines(data)
      next if lines.blank?

      call_ref = data['call_sid'].presence || data['call_ref'].presence || data['transcript_ref'].presence || message.id
      seen_call_refs << call_ref.to_s
      "Call #{call_ref}:\n#{lines.join("\n")}"
    end

    sections.concat(voice_transcripts_from_call_sessions(seen_call_refs))
    sections.join("\n")
  end

  def voice_transcript_lines(data)
    items = Array(data['transcript_items']).filter_map do |item|
      item = item.to_h
      text = item['text'].to_s.strip
      next if text.blank?

      "#{voice_speaker_label(item['speaker'])}: #{text}"
    end
    return items if items.present?

    data['transcript'].to_s.lines.map(&:strip).reject(&:blank?)
  end

  def voice_speaker_label(speaker)
    case speaker.to_s
    when 'caller', 'customer', 'contact', 'user'
      'User'
    when 'ai', 'assistant', 'bot'
      'AI Voice Agent'
    when 'agent', 'operator'
      'Support Agent'
    else
      speaker.to_s.presence&.humanize || 'Voice'
    end
  end

  def voice_transcripts_from_call_sessions(seen_call_refs)
    @record.telephony_call_sessions.order(created_at: :asc).filter_map do |call_session|
      call_ref = call_session.external_call_ref.to_s
      next if call_ref.blank? || seen_call_refs.include?(call_ref)

      lines = voice_transcript_lines('transcript_items' => call_session_transcript_items(call_session))
      next if lines.blank?

      "Call #{call_ref}:\n#{lines.join("\n")}"
    end
  end

  def call_session_transcript_items(call_session)
    call_session.metadata&.dig('ai_voice', 'transcript', 'final_items') ||
      call_session.metadata&.dig('ai_voice', 'final_transcript')
  end

  def build_attributes
    attributes = @record.account.custom_attribute_definitions.with_attribute_model('conversation_attribute').map do |attribute|
      "#{attribute.attribute_display_name}: #{@record.custom_attributes[attribute.attribute_key]}"
    end
    attributes.join("\n")
  end
end
