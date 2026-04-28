class Telephony::AiVoice::TranscriptIngestionService
  TRANSCRIPT_METADATA_KEY = 'ai_voice'.freeze

  def initialize(payload:)
    @payload = payload.deep_stringify_keys
  end

  def perform
    ensure_call_session!
    normalized_items = transcript_items
    update_call_session!(normalized_items)
    upsert_final_message!(normalized_items) if final_transcript?(normalized_items)

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

  def upsert_final_message!(items)
    return if conversation.blank?

    final_items = ((call_session.metadata.dig(TRANSCRIPT_METADATA_KEY, 'transcript', 'final_items') || []) + items.select { |item| item['final'] })
                  .uniq { |item| item.slice('speaker', 'text', 'at') }
    content = final_items.filter_map do |item|
      next if item['text'].blank?

      "#{item['speaker']}: #{item['text']}"
    end.join("\n")
    return if content.blank?

    message = conversation.messages.find_or_initialize_by(source_id: transcript_ref)
    message.assign_attributes(
      account_id: conversation.account_id,
      inbox_id: conversation.inbox_id,
      message_type: :activity,
      content_type: :text,
      private: true,
      content: content,
      content_attributes: {
        data: {
          type: 'ai_voice_transcript',
          call_ref: call_session.external_call_ref,
          final: true
        }
      }
    )
    message.save!
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
