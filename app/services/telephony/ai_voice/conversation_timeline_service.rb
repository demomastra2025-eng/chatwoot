class Telephony::AiVoice::ConversationTimelineService
  TRANSCRIPT_SOURCE_PREFIX = 'ai_voice_turn'.freeze
  EVENT_SOURCE_PREFIX = 'ai_voice_event'.freeze
  TRANSCRIPT_TYPE = 'ai_voice_transcript_turn'.freeze
  EVENT_TYPE = 'ai_voice_event'.freeze
  TOOL_ACTIONS = %w[tool_started tool_completed tool_failed].freeze
  TOOL_EVENTS = {
    'tool_started' => 'start',
    'tool_completed' => 'complete',
    'tool_failed' => 'failed'
  }.freeze
  TOOL_CONTENT = {
    'start' => 'Using %<tool_name>s',
    'complete' => 'Completed %<tool_name>s',
    'failed' => 'Failed %<tool_name>s'
  }.freeze
  TOOL_TRACE_STATUSES = {
    'start' => 'running',
    'complete' => 'completed',
    'failed' => 'failed'
  }.freeze
  SYSTEM_CONTENT = {
    'ai_ringing' => 'ИИ принимает звонок',
    'ai_answered' => 'ИИ ответил на звонок',
    'ai_speaking' => 'ИИ отвечает клиенту',
    'caller_interrupted' => 'Клиент перебил ответ ИИ',
    'transfer_started' => 'Начат перевод звонка оператору',
    'transfer_answered' => 'Оператор ответил на перевод',
    'transfer_completed' => 'Звонок переведен оператору',
    'transfer_failed' => 'Не удалось перевести звонок оператору',
    'session_completed' => 'AI-звонок завершен',
    'session_failed' => 'AI-звонок завершился с ошибкой',
    'caller_hangup' => 'Клиент завершил звонок',
    'media_stream_closed' => 'Медиа-поток звонка закрыт',
    'media_stream_not_established' => 'Медиа-поток звонка не установился',
    'provider_stream_closed' => 'Провайдер закрыл realtime-поток',
    'provider_error' => 'Ошибка realtime-провайдера',
    'fonoster_call_closed' => 'Fonoster закрыл звонок',
    'runtime_closed' => 'Voice runtime закрыл сессию',
    'tool_requested_end_call' => 'Инструмент запросил завершение звонка',
    'handoff_requested' => 'ИИ запросил передачу оператору',
    'close' => 'AI-сессия закрыта',
    'post_tool_model_stall' => 'ИИ не продолжил ответ после инструмента'
  }.freeze

  def initialize(call_session:)
    @call_session = call_session
  end

  def sync_transcript_turns!
    return if conversation.blank?

    transcript_turns(final_transcript_items).each_with_index do |turn, index|
      upsert_transcript_turn!(turn, index)
    end
    attach_tool_trace_to_latest_ai_message!
  end

  def record_control_event!(action:, metadata:, sequence:)
    return if conversation.blank?

    upsert_activity_event!(action: action.to_s, metadata: metadata.to_h.deep_stringify_keys, sequence: sequence)
    attach_tool_trace_to_latest_ai_message! if TOOL_ACTIONS.include?(action.to_s)
  end

  private

  attr_reader :call_session

  def upsert_transcript_turn!(turn, index)
    speaker = turn['speaker']
    content = turn_content(turn)
    return if content.blank?

    message = conversation.messages.find_or_initialize_by(source_id: transcript_source_id(index, speaker))
    message.assign_attributes(
      account_id: account.id,
      inbox_id: conversation.inbox_id,
      message_type: speaker == 'ai' ? :outgoing : :incoming,
      content_type: :text,
      private: false,
      content: content,
      sender: transcript_sender(speaker),
      content_attributes: transcript_content_attributes(turn, index)
    )
    message.additional_attributes = ai_additional_attributes(message) if speaker == 'ai'
    message.created_at ||= turn_started_at(turn)
    message.skip_send_reply = true if speaker == 'ai'
    message.save!
  end

  def upsert_activity_event!(action:, metadata:, sequence:)
    content = activity_content(action, metadata)
    return if content.blank?

    message = conversation.messages.find_or_initialize_by(source_id: event_source_id(action, metadata, sequence))
    message.assign_attributes(
      account_id: account.id,
      inbox_id: conversation.inbox_id,
      message_type: :activity,
      content_type: :text,
      private: false,
      content: content,
      content_attributes: {
        data: {
          type: EVENT_TYPE,
          call_ref: call_session.external_call_ref,
          action: action,
          metadata: safe_event_metadata(metadata),
          sequence: sequence
        }
      }
    )
    message.save!
  end

  def attach_tool_trace_to_latest_ai_message!
    trace = captain_trace_payload
    return if trace.blank?

    message = latest_ai_transcript_message
    return if message.blank?

    attrs = (message.additional_attributes || {}).deep_dup
    attrs['captain_trace'] = trace
    message.update!(additional_attributes: attrs)
  end

  def latest_ai_transcript_message
    conversation.messages.outgoing
                .where('source_id LIKE ?', "#{TRANSCRIPT_SOURCE_PREFIX}:#{escaped_call_ref}:%:ai")
                .order(created_at: :desc, id: :desc)
                .first
  end

  def ai_additional_attributes(message)
    attrs = (message.additional_attributes || {}).deep_dup
    trace = captain_trace_payload
    attrs['captain_trace'] = trace if trace.present?
    attrs
  end

  def transcript_turns(items)
    items.each_with_object([]) do |item, turns|
      speaker = item['speaker'].to_s
      next unless %w[caller ai].include?(speaker)
      next if item['text'].blank?

      if turns.last&.fetch('speaker') == speaker
        turns.last['items'] << item
      else
        turns << { 'speaker' => speaker, 'items' => [item] }
      end
    end
  end

  def final_transcript_items
    transcript = call_session.metadata.to_h.dig('ai_voice', 'transcript') || {}
    Array.wrap(transcript['final_items'])
  end

  def turn_content(turn)
    turn['items'].filter_map { |item| item['text'].to_s.strip.presence }.join(' ')
  end

  def turn_started_at(turn)
    turn['items'].filter_map { |item| parse_time(item['at']) }.min
  end

  def transcript_source_id(index, speaker)
    "#{TRANSCRIPT_SOURCE_PREFIX}:#{call_session.external_call_ref}:#{index}:#{speaker}"
  end

  def transcript_content_attributes(turn, index)
    {
      data: {
        type: TRANSCRIPT_TYPE,
        call_ref: call_session.external_call_ref,
        transcript_ref: transcript_ref,
        speaker: turn['speaker'],
        turn_index: index,
        final: true,
        items: turn['items']
      }
    }
  end

  def transcript_sender(speaker)
    return conversation.contact if speaker == 'caller'
    return captain_assistant if captain_assistant.present?

    nil
  end

  def activity_content(action, metadata)
    return tool_activity_content(action, metadata) if TOOL_ACTIONS.include?(action)

    SYSTEM_CONTENT[action].presence || humanize_action(action)
  end

  def tool_activity_content(action, metadata)
    tool_name = metadata['tool_name'].presence || 'tool'
    case action
    when 'tool_started'
      "Инструмент #{tool_name} запущен"
    when 'tool_completed'
      "Инструмент #{tool_name} выполнен"
    when 'tool_failed'
      error = metadata['error'].to_s.strip
      error.present? ? "Инструмент #{tool_name} завершился с ошибкой: #{error}" : "Инструмент #{tool_name} завершился с ошибкой"
    end
  end

  def humanize_action(action)
    "Voice event: #{action.to_s.tr('_', ' ')}"
  end

  def event_source_id(action, metadata, sequence)
    suffix = metadata['tool_call_id'].presence || sequence.presence || SecureRandom.uuid
    "#{EVENT_SOURCE_PREFIX}:#{call_session.external_call_ref}:#{action}:#{suffix}"
  end

  def safe_event_metadata(metadata)
    metadata.slice('tool_name', 'tool_call_id', 'provider', 'ok', 'error', 'timeout_ms', 'reason', 'source', 'final_status')
  end

  def captain_trace_payload
    steps = tool_control_events.filter_map.with_index do |event, index|
      metadata = event['metadata'].is_a?(Hash) ? event['metadata'].deep_stringify_keys : {}
      trace_event = TOOL_EVENTS[event['action'].to_s]
      tool_name = metadata['tool_name'].presence
      next if trace_event.blank? || tool_name.blank?

      content = format(TOOL_CONTENT.fetch(trace_event), tool_name: tool_name)
      content = "#{content}: #{metadata['error']}" if trace_event == 'failed' && metadata['error'].present?
      {
        'id' => "#{tool_name}:#{trace_event}:#{metadata['tool_call_id'].presence || index}",
        'tool_name' => tool_name,
        'event' => trace_event,
        'status' => tool_trace_status(trace_event),
        'content' => content
      }
    end
    return if steps.blank?

    { 'version' => 1, 'tool_steps' => steps.last(20) }
  end

  def tool_control_events
    Array.wrap(call_session.metadata.to_h.dig('ai_voice', 'control_events')).select do |event|
      TOOL_ACTIONS.include?(event['action'].to_s)
    end
  end

  def tool_trace_status(event)
    TOOL_TRACE_STATUSES[event]
  end

  def captain_assistant
    @captain_assistant ||= inbox_captain_assistant || routing_policy&.captain_assistant
  end

  def inbox_captain_assistant
    inbox = call_session.inbox || conversation.inbox
    return unless inbox.respond_to?(:captain_assistant)

    inbox.captain_assistant
  end

  def routing_policy
    call_session.number_binding&.routing_policy
  end

  def conversation
    @conversation ||= call_session.conversation
  end

  def account
    @account ||= call_session.account
  end

  def transcript_ref
    "ai_voice_transcript:#{call_session.external_call_ref}"
  end

  def escaped_call_ref
    ActiveRecord::Base.sanitize_sql_like(call_session.external_call_ref.to_s)
  end

  def parse_time(value)
    return if value.blank?

    Time.zone.parse(value.to_s)
  rescue ArgumentError
    nil
  end
end
