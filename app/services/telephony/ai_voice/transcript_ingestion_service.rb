class Telephony::AiVoice::TranscriptIngestionService
  TRANSCRIPT_METADATA_KEY = 'ai_voice'.freeze

  def initialize(payload:)
    @payload = payload.deep_stringify_keys
  end

  def perform
    ensure_call_session!
    normalized_items = transcript_items

    call_session.with_lock do
      call_session.reload
      update_call_session!(normalized_items)
      sync_voice_message_transcript!
      remove_legacy_transcript_messages!
      sync_conversation_timeline!
    end

    {
      status: 'ok',
      accepted: normalized_items.length,
      final_count: normalized_items.count { |item| item['final'] },
      partial_count: normalized_items.count { |item| !item['final'] }
    }
  end

  private

  attr_reader :payload

  def ensure_call_session!
    return if call_session.present?

    raise Telephony::Error.new(code: 'CALL_SESSION_NOT_FOUND', message: 'Unable to resolve call session for transcript', status: :not_found)
  end

  def update_call_session!(items)
    metadata = (call_session.metadata || {}).deep_dup
    ai_voice = metadata[TRANSCRIPT_METADATA_KEY] ||= {}
    transcript = ai_voice['transcript'] ||= {}
    transcript['partial_items'] = merge_items(transcript['partial_items'], items.reject { |item| item['final'] })
    transcript['final_items'] = merge_items(transcript['final_items'], items.select { |item| item['final'] })
    transcript['updated_at'] = Time.current.iso8601

    attrs = { metadata: metadata }
    attrs[:transcript_ref] = transcript_ref if final_transcript?(items)
    call_session.update!(attrs)
  end

  def sync_voice_message_transcript!
    message = call_session.voice_message_for_current_call
    return if message.blank?

    data = (message.content_attributes || {}).deep_dup
    data['data'] ||= {}
    transcript_items = voice_message_transcript_items
    data['data']['transcript_ref'] = transcript_ref if final_transcript?(transcript_items)
    data['data']['transcript_items'] = transcript_items
    data['data']['transcript'] = transcript_text(transcript_items)
    data['data']['ai_voice'] = (data['data']['ai_voice'].is_a?(Hash) ? data['data']['ai_voice'] : {}).merge(
      'enabled' => true,
      'transcript_updated_at' => Time.current.iso8601,
      'transcript_final' => transcript_items.any? { |item| item['final'] },
      'timeline_messages_enabled' => true
    )
    message.update!(content_attributes: data)
  end

  def voice_message_transcript_items
    transcript = call_session.metadata.dig(TRANSCRIPT_METADATA_KEY, 'transcript') || {}
    items = Array.wrap(transcript['final_items']) + Array.wrap(transcript['partial_items'])
    items.uniq { |item| item.slice('speaker', 'text', 'at', 'final') }.last(200)
  end

  def transcript_text(items)
    transcript_turns(items.select { |item| item['final'] }).map do |turn|
      "#{speaker_label(turn['speaker'])}: #{turn_content(turn)}"
    end.join("\n")
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

  def turn_content(turn)
    turn['items'].filter_map { |item| item['text'].to_s.strip.presence }.join(' ')
  end

  def speaker_label(speaker)
    speaker == 'ai' ? 'ИИ' : 'Клиент'
  end

  def remove_legacy_transcript_messages!
    return if conversation.blank?

    conversation.messages.where(source_id: transcript_ref).find_each do |message|
      next unless message.private? && message.activity?
      next unless message.content_attributes.to_h.dig('data', 'type') == 'ai_voice_transcript'

      message.destroy!
    end
    legacy_turn_source = "ai_voice_turn:#{ActiveRecord::Base.sanitize_sql_like(call_session.external_call_ref)}:%"
    legacy_turn_pattern = /\Aai_voice_turn:#{Regexp.escape(call_session.external_call_ref)}:\d+\z/
    conversation.messages.where('source_id LIKE ?', legacy_turn_source).find_each do |message|
      message.destroy! if message.source_id.to_s.match?(legacy_turn_pattern)
    end
  end

  def sync_conversation_timeline!
    Telephony::AiVoice::ConversationTimelineService.new(call_session: call_session).sync_transcript_turns!
  end

  def merge_items(existing_items, new_items)
    (Array.wrap(existing_items) + new_items).uniq { |item| item.slice('speaker', 'text', 'at', 'final') }.last(200)
  end

  def final_transcript?(items)
    ActiveModel::Type::Boolean.new.cast(payload['final']) || items.any? { |item| item['final'] }
  end

  def transcript_ref
    "ai_voice_transcript:#{call_session.external_call_ref}"
  end

  def transcript_items
    Array.wrap(payload['items']).filter_map do |item|
      item = item.deep_stringify_keys
      text = item['text'].to_s.strip
      next if text.blank?

      {
        'speaker' => normalized_speaker(item['speaker']),
        'text' => text,
        'final' => ActiveModel::Type::Boolean.new.cast(item['final'] || payload['final']),
        'at' => parse_time(item['at'] || item['occurred_at'] || item['occurredAt'])&.iso8601 || Time.current.iso8601
      }
    end
  end

  def normalized_speaker(value)
    return 'ai' if value.to_s == 'assistant'

    value.to_s.presence_in(%w[caller ai operator system]) || 'system'
  end

  def conversation
    @conversation ||= call_session.conversation
  end

  def call_session
    @call_session ||= Telephony::AiVoice::CallSessionResolver.new(payload: payload).call_session
  end

  def parse_time(value)
    return if value.blank?

    Time.zone.parse(value.to_s)
  rescue ArgumentError
    nil
  end
end
