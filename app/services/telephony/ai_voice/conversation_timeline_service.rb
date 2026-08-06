class Telephony::AiVoice::ConversationTimelineService
  TRANSCRIPT_SOURCE_PREFIX = 'ai_voice_turn'.freeze
  EVENT_SOURCE_PREFIX = 'ai_voice_event'.freeze
  TRANSCRIPT_TYPE = 'ai_voice_transcript_turn'.freeze
  EVENT_TYPE = 'ai_voice_event'.freeze
  TOOL_ACTIONS = %w[tool_started tool_progress tool_completed tool_failed tool_suppressed tool_async_completed tool_async_failed].freeze
  INTERNAL_OBSERVABILITY_ACTIONS = %w[
    ai_speaking
    business_faq_gate_fired
    business_faq_gate_result_injected
    direct_tool_context_barrier_timeout
    direct_tool_speech_deferred
    direct_tool_speech_not_started
    incomplete_answer_model_stall
    ordinary_answer_model_stall
    post_tool_model_stall
    tool_result_deferred
    tool_result_delivery_completed
    tool_result_delivery_failed
    terminal_confirmation_missing
  ].freeze
  TOOL_EVENTS = {
    'tool_started' => 'start',
    'tool_progress' => 'progress',
    'tool_completed' => 'finish',
    'tool_failed' => 'failed',
    'tool_suppressed' => 'suppressed',
    'tool_async_completed' => 'finish',
    'tool_async_failed' => 'failed'
  }.freeze
  TOOL_CONTENT = {
    'start' => 'Using %<tool_name>s',
    'progress' => 'Running %<tool_name>s',
    'finish' => 'Completed %<tool_name>s',
    'failed' => 'Failed %<tool_name>s',
    'suppressed' => 'Suppressed duplicate %<tool_name>s'
  }.freeze
  TOOL_TRACE_STATUSES = {
    'start' => 'start',
    'progress' => 'progress',
    'finish' => 'finish',
    'failed' => 'failed',
    'suppressed' => 'suppressed'
  }.freeze
  SYSTEM_CONTENT = {
    'ai_ringing' => 'AI-агент принимает звонок',
    'ai_answered' => 'AI-агент ответил на звонок',
    'ai_speaking' => 'AI-агент отвечает клиенту',
    'caller_interrupted' => 'Клиент перебил ответ AI-агента',
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
    'provider_call_closed' => 'Провайдер закрыл звонок',
    'runtime_closed' => 'Voice runtime закрыл сессию',
    'tool_requested_end_call' => 'Инструмент запросил завершение звонка',
    'handoff_requested' => 'AI-агент запросил передачу оператору',
    'close' => 'AI-сессия закрыта',
    'post_tool_model_stall' => 'AI-агент не продолжил ответ после инструмента',
    'business_faq_gate_fired' => 'AI-агент проверяет базу знаний',
    'business_faq_gate_result_injected' => 'AI-агент получил результат базы знаний',
    'ordinary_answer_model_stall' => 'AI-агенту отправлен запрос продолжить ответ',
    'incomplete_answer_model_stall' => 'AI-агенту отправлен запрос договорить оборванный ответ'
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

    normalized_action = action.to_s
    return if INTERNAL_OBSERVABILITY_ACTIONS.include?(normalized_action)

    if TOOL_ACTIONS.include?(normalized_action)
      attach_tool_trace_to_latest_ai_message!
      return
    end

    upsert_activity_event!(action: normalized_action, metadata: metadata.to_h.deep_stringify_keys, sequence: sequence)
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
    message.additional_attributes = ai_additional_attributes(message, turn) if speaker == 'ai'
    message.created_at ||= turn_started_at(turn)
    message.skip_send_reply = true if speaker == 'ai'
    message.save! if message.new_record? || message.changed?
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
    existing_trace = attrs['captain_trace'].is_a?(Hash) ? attrs['captain_trace'] : {}
    attrs['captain_trace'] = existing_trace.merge(trace)
    message.update!(additional_attributes: attrs) if message.additional_attributes != attrs
  end

  def latest_ai_transcript_message
    conversation.messages.outgoing
                .where('source_id LIKE ?', "#{TRANSCRIPT_SOURCE_PREFIX}:#{escaped_call_ref}:%:ai")
                .order(created_at: :desc, id: :desc)
                .first
  end

  def ai_additional_attributes(message, turn)
    attrs = (message.additional_attributes || {}).deep_dup
    attrs.delete('captain_trace')
    trace = turn_trace_payload(turn)
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
    Array.wrap(transcript['final_items']).map { |item| Telephony::AiVoice::TranscriptItemNormalizer.call(item) }
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
        items: turn['items'].map { |item| Telephony::AiVoice::TranscriptItemNormalizer.presentation_item(item) }
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
    when 'tool_completed', 'tool_async_completed'
      "Инструмент #{tool_name} выполнен"
    when 'tool_failed', 'tool_async_failed'
      error = metadata['error'].to_s.strip
      error.present? ? "Инструмент #{tool_name} завершился с ошибкой: #{error}" : "Инструмент #{tool_name} завершился с ошибкой"
    end
  end

  def humanize_action(action)
    "Voice event: #{action.to_s.tr('_', ' ')}"
  end

  def event_source_id(action, metadata, sequence)
    suffix = metadata['tool_call_id'].presence || metadata['request_id'].presence || metadata['requestId'].presence ||
             sequence.presence || SecureRandom.uuid
    "#{EVENT_SOURCE_PREFIX}:#{call_session.external_call_ref}:#{action}:#{suffix}"
  end

  def safe_event_metadata(metadata)
    metadata.slice(
      'tool_name', 'tool_call_id', 'request_id', 'requestId', 'provider', 'ok', 'pending', 'async', 'error',
      'timeout_ms', 'reason', 'source', 'final_status'
    )
  end

  def captain_trace_payload
    steps = tool_control_events.filter_map.with_index { |event, index| tool_trace_step(event, index) }
    return if steps.blank?

    Captain::ToolTraceBuilder.payload(steps.last(20))
  end

  def turn_trace_payload(turn)
    reasoning = turn_reasoning_payload(turn)
    return if reasoning.blank?

    Captain::ToolTraceBuilder.payload(nil, reasoning: reasoning)
  end

  def turn_reasoning_payload(turn)
    Array.wrap(turn['items']).filter_map do |item|
      item['reasoning'].to_s.strip.presence
    end.uniq.join("\n").presence
  end

  def tool_trace_step(event, index)
    metadata = event['metadata'].is_a?(Hash) ? event['metadata'].deep_stringify_keys : {}
    trace_event = TOOL_EVENTS[event['action'].to_s]
    tool_name = metadata['tool_name'].presence
    return if trace_event.blank? || tool_name.blank?

    Captain::ToolTraceBuilder.step(
      tool_name: tool_name,
      event: trace_event,
      sequence: index,
      tool_call_id: metadata['tool_call_id'].presence || metadata['request_id'].presence || metadata['requestId'].presence,
      input: metadata['input'].presence,
      output: tool_trace_output(trace_event, metadata),
      error: metadata['error'].presence,
      message: tool_trace_content(trace_event, tool_name, metadata)
    )
  end

  def tool_trace_output(trace_event, metadata)
    return metadata['output'] if metadata['output'].present?
    return { error: metadata['error'] } if trace_event == 'failed' && metadata['error'].present?
  end

  def tool_control_events
    Array.wrap(call_session.metadata.to_h.dig('ai_voice', 'control_events')).select do |event|
      TOOL_ACTIONS.include?(event['action'].to_s)
    end
  end

  def tool_trace_content(event, tool_name, metadata)
    content = format(TOOL_CONTENT.fetch(event), tool_name: tool_name)
    content = "#{content}: #{metadata['error']}" if event == 'failed' && metadata['error'].present?
    content
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
