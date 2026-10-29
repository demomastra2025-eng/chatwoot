class Contacts::LanguageStatsService
  MESSAGE_SAMPLE_LIMIT = 200
  CALL_SAMPLE_LIMIT = 100
  CLIENT_SPEAKERS = %w[client caller customer contact user cl patient клиент].to_set.freeze
  CALL_DATA_KEYS = %w[call_id call_session_id external_call_ref call_direction transcript_items transcript recording].freeze

  def self.refresh!(contact, fallback_language: nil)
    return false unless contact.is_a?(Contact) && contact.persisted?

    new(contact, fallback_language: fallback_language).refresh!
  rescue StandardError => e
    Rails.logger.warn("[Contacts::LanguageStatsService] failed contact_id=#{contact&.id} error=#{e.class.name}")
    false
  end

  def self.analyze_texts(texts)
    Contacts::LanguageTextAnalyzer.analyze(texts)
  end

  def self.breakdown_from_counts(counts)
    return [] unless counts.is_a?(Hash)

    normalized = counts.each_with_object(Hash.new(0.0)) do |(raw_code, raw_val), acc|
      code = Whatsapp::SupportedLanguages.normalize_code(raw_code)
      val = raw_val.to_f
      acc[code] += val if code.present? && val.positive?
    end
    Contacts::LanguageTextAnalyzer.normalize_weights(normalized)
  end

  def self.resolve_stored_breakdown(raw_attributes, fallback_code = nil)
    attrs = (raw_attributes || {}).deep_stringify_keys
    parsed = parse_stored_breakdown_items(attrs[Contact::CLIENT_LANGUAGE_BREAKDOWN_KEY])
    return parsed if parsed.any?

    from_counts = breakdown_from_counts(attrs[Contact::CLIENT_LANGUAGE_COUNTS_KEY])
    return from_counts if from_counts.any?

    code = Whatsapp::SupportedLanguages.normalize_code(fallback_code || attrs[Contact::CLIENT_LANGUAGE_KEY])
    code.present? ? [{ 'code' => code, 'percentage' => 100 }] : []
  end

  def self.parse_stored_breakdown_items(stored)
    Array(stored).filter_map { |entry| parse_breakdown_entry(entry) if entry.is_a?(Hash) }
  end

  def self.parse_breakdown_entry(entry)
    data = entry.stringify_keys
    code = Whatsapp::SupportedLanguages.normalize_code(data['code'])
    pct = Integer(data['percentage'].to_s, 10, exception: false)
    { 'code' => code, 'percentage' => pct } if code.present? && pct.to_i.positive?
  end

  def self.backfill_scope!(scope = Contact.all, batch_size: 200)
    stats = { processed: 0, updated: 0 }
    scope.find_each(batch_size: batch_size) do |c|
      before = c.additional_attributes.to_h
      refresh!(c)
      stats[:processed] += 1
      stats[:updated] += 1 if c.additional_attributes.to_h != before
    end
    stats
  end

  def initialize(contact, fallback_language: nil)
    @contact = contact
    @fallback_language = Whatsapp::SupportedLanguages.normalize_code(fallback_language)
  end

  def refresh!
    persist_breakdown!(self.class.analyze_texts(collect_client_texts))
    true
  end

  private

  attr_reader :contact, :fallback_language

  def collect_client_texts
    seen_calls = { ids: Set.new, refs: Set.new }
    collect_message_texts(seen_calls) + collect_call_session_texts(seen_calls)
  end

  def collect_message_texts(seen_calls)
    rows = fetch_incoming_message_rows
    return [] if rows.empty?

    audio_by_msg = load_audio_transcriptions(rows.map(&:first))
    rows.flat_map { |row| extract_row_texts(row, audio_by_msg, seen_calls) }
  end

  def fetch_incoming_message_rows
    scope = Message.joins(:conversation).where(conversations: { contact_id: contact.id }, private: false)
                   .where('messages.message_type = ? OR messages.content_type = ?',
                          Message.message_types[:incoming], Message.content_types[:voice_call])
    scope.reorder(created_at: :desc, id: :desc).limit(MESSAGE_SAMPLE_LIMIT)
         .pluck(:id, :content_type, :content, :content_attributes).reverse
  end

  def load_audio_transcriptions(ids)
    rows = Attachment.where(message_id: ids, file_type: Attachment.file_types[:audio]).pluck(:message_id, :meta)
    rows.each_with_object(Hash.new { |h, k| h[k] = [] }) do |(msg_id, meta), acc|
      text = meta.is_a?(Hash) ? meta['transcribed_text'].to_s.strip : ''
      acc[msg_id] << text if text.present?
    end
  end

  def extract_row_texts(row, audio_by_msg, seen_calls)
    id, content_type, content, raw_attrs = row
    attrs = raw_attrs.is_a?(Hash) ? raw_attrs.deep_stringify_keys : {}
    return [] if auto_reply_attrs?(attrs)

    if call_message?(content_type, attrs)
      record_seen_call(attrs['data'], seen_calls)
      return extract_client_call_turns(attrs['data'])
    end

    [content.to_s.strip.presence, *audio_by_msg[id]].compact
  end

  def auto_reply_attrs?(attrs)
    attrs['is_auto_reply'] == true || attrs.dig('email', 'auto_reply') == true
  end

  def call_message?(content_type, attrs)
    return true if content_type.to_s == 'voice_call' || content_type == Message.content_types[:voice_call]

    data = attrs['data']
    data.is_a?(Hash) && CALL_DATA_KEYS.any? { |key| data.key?(key) }
  end

  def record_seen_call(data, seen_calls)
    return unless data.is_a?(Hash)

    session_id = data['call_session_id']
    seen_calls[:ids] << session_id.to_i if session_id.present?
    call_ref = data['external_call_ref'].presence || data['call_id'].presence
    seen_calls[:refs] << call_ref.to_s if call_ref.present?
  end

  def extract_client_call_turns(data)
    return [] unless data.is_a?(Hash)

    items = data['transcript_items'].presence || data.dig('recording', 'transcription', 'transcript_items')
    filter_client_turns(items)
  end

  def collect_call_session_texts(seen_calls)
    rows = Telephony::CallSession.where(contact_id: contact.id).reorder(created_at: :desc, id: :desc)
                                 .limit(CALL_SAMPLE_LIMIT).pluck(:id, :external_call_ref, :metadata)
    rows.reverse.flat_map { |id, call_ref, meta| extract_session_turns(id, call_ref, meta, seen_calls) }
  end

  def extract_session_turns(id, call_ref, metadata, seen_calls)
    return [] if seen_calls[:ids].include?(id) || (call_ref.present? && seen_calls[:refs].include?(call_ref.to_s))
    return [] unless metadata.is_a?(Hash)

    items = metadata.dig('recording', 'transcription', 'transcript_items').presence ||
            metadata.dig('ai_voice', 'transcript', 'final_items')
    filter_client_turns(items)
  end

  def filter_client_turns(items)
    Array(items).filter_map do |item|
      next unless item.is_a?(Hash)

      speaker = (item['speaker'] || item[:speaker]).to_s.strip.downcase
      text = (item['text'] || item[:text]).to_s.strip
      text if text.present? && CLIENT_SPEAKERS.include?(speaker)
    end
  end

  def persist_breakdown!(breakdown)
    contact.with_lock do
      current = (contact.additional_attributes || {}).deep_stringify_keys
      updated = build_updated_attributes(current.deep_dup, breakdown)
      return if updated == current

      contact.update_columns(additional_attributes: updated) # rubocop:disable Rails/SkipsModelValidations
    end
  end

  def build_updated_attributes(attrs, breakdown)
    return apply_detected_breakdown(attrs, breakdown) if breakdown.present?
    return apply_fallback_language(attrs) if fallback_language.present?
    return attrs.except(*Contact::SERVER_OWNED_CLIENT_LANGUAGE_KEYS) if manual_source?(attrs)

    attrs
  end

  def manual_source?(attrs)
    attrs[Contact::CLIENT_LANGUAGE_SOURCE_KEY] == Contact::CLIENT_LANGUAGE_SOURCE_MANUAL
  end

  def apply_detected_breakdown(attrs, breakdown, counts_override = nil)
    top = breakdown.first
    attrs[Contact::CLIENT_LANGUAGE_BREAKDOWN_KEY] = breakdown
    attrs[Contact::CLIENT_LANGUAGE_KEY] = top['code']
    attrs[Contact::CLIENT_LANGUAGE_CONFIDENCE_KEY] = top['percentage']
    attrs[Contact::CLIENT_LANGUAGE_SOURCE_KEY] = Contact::CLIENT_LANGUAGE_SOURCE_AI
    attrs[Contact::CLIENT_LANGUAGE_COUNTS_KEY] = counts_override || breakdown.to_h { |item| [item['code'], item['percentage']] }
    attrs
  end

  def apply_fallback_language(attrs)
    counts = incremented_fallback_counts(attrs)
    breakdown = self.class.breakdown_from_counts(counts).presence || [{ 'code' => fallback_language, 'percentage' => 100 }]
    apply_detected_breakdown(attrs, breakdown, counts)
  end

  def incremented_fallback_counts(attrs)
    raw = attrs[Contact::CLIENT_LANGUAGE_COUNTS_KEY]
    counts = raw.is_a?(Hash) ? raw.deep_stringify_keys : {}
    existing = Whatsapp::SupportedLanguages.normalize_code(attrs[Contact::CLIENT_LANGUAGE_KEY])
    counts[existing] = 1 if counts.empty? && existing.present?
    counts[fallback_language] = counts[fallback_language].to_i + 1
    counts
  end
end
