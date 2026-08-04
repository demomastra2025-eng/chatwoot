class Telephony::AiVoice::PostCallCaptainFeaturesService
  FEATURE_MEMORY = 'memory'.freeze
  FEATURE_FAQ = 'faq'.freeze
  FEATURE_START_LEASE_DURATION = 15.minutes

  def initialize(call_session:)
    @call_session = call_session
  end

  def perform
    return unless ready_to_run?

    run_enabled_features
  end

  private

  attr_reader :call_session

  def ready_to_run?
    call_session.present? && conversation.present? && captain_assistant.present? &&
      captain_usage_available? && voice_transcript_present?
  end

  def run_enabled_features
    run_memory_feature if feature_enabled?('feature_memory')
    run_faq_feature if feature_enabled?('feature_faq')
  end

  def run_memory_feature
    run_feature(FEATURE_MEMORY) do
      Captain::Llm::ContactNotesService.new(
        captain_assistant,
        conversation,
        conversation_content: voice_transcript_content,
        raise_on_error: true
      ).generate_and_update_notes
    end
  end

  def run_faq_feature
    run_feature(FEATURE_FAQ) do
      Captain::Llm::ConversationFaqService.new(
        captain_assistant,
        conversation,
        content: voice_transcript_content,
        raise_on_error: true
      ).generate_and_deduplicate
    end
  end

  def run_feature(feature_name)
    return unless mark_feature_started!(feature_name)

    yield
    record_feature_result!(feature_name, 'completed_at' => Time.current.iso8601)
  rescue StandardError => e
    record_feature_result!(
      feature_name,
      'failed_at' => Time.current.iso8601,
      'error_class' => e.class.name,
      'error_message' => e.message.to_s.truncate(500)
    )
    ChatwootExceptionTracker.new(e, account: call_session.account).capture_exception
  end

  def mark_feature_started!(feature_name)
    call_session.with_lock do
      metadata = (call_session.reload.metadata || {}).deep_dup
      ai_voice = metadata['ai_voice'] ||= {}
      features = ai_voice['post_call_captain_features'] ||= {}
      current_result = features[feature_name] || {}
      next false if feature_active?(current_result)

      features[feature_name] = started_feature_result(current_result)
      call_session.update!(metadata: metadata)
      true
    end
  end

  def feature_active?(result)
    return true if result['completed_at'].present?
    return false if result['failed_at'].present?

    started_at = feature_started_at(result)
    started_at.present? && started_at > FEATURE_START_LEASE_DURATION.ago
  end

  def feature_started_at(result)
    Time.zone.parse(result['started_at'].to_s) if result['started_at'].present?
  rescue ArgumentError, TypeError
    nil
  end

  def started_feature_result(current_result)
    current_result.merge(
      'assistant_id' => captain_assistant.id,
      'call_ref' => call_session.external_call_ref,
      'started_at' => Time.current.iso8601
    ).except('failed_at', 'error_class', 'error_message')
  end

  def record_feature_result!(feature_name, attrs)
    call_session.with_lock do
      metadata = (call_session.reload.metadata || {}).deep_dup
      ai_voice = metadata['ai_voice'] ||= {}
      features = ai_voice['post_call_captain_features'] ||= {}
      existing_result = features[feature_name] || {}
      existing_result = existing_result.except('failed_at', 'error_class', 'error_message') if attrs['completed_at'].present?
      features[feature_name] = existing_result.merge(
        'assistant_id' => captain_assistant.id,
        'call_ref' => call_session.external_call_ref
      ).merge(attrs)
      call_session.update!(metadata: metadata)
    end
  end

  def feature_enabled?(key)
    ActiveModel::Type::Boolean.new.cast(captain_assistant.config&.dig(key))
  end

  def captain_usage_available?
    return true unless call_session.account.respond_to?(:captain_quota_available?)

    call_session.account.captain_quota_available?
  end

  def voice_transcript_present?
    voice_transcript_content.present?
  end

  def voice_transcript_content
    @voice_transcript_content ||= voice_transcript_items.filter_map do |raw_item|
      item = raw_item.to_h.with_indifferent_access
      text = item[:text].to_s.strip
      next if text.blank?

      "#{voice_speaker_label(item[:speaker])}: #{text}"
    end.join("\n")
  end

  def voice_transcript_items
    Array(
      call_session.metadata&.dig('ai_voice', 'transcript', 'final_items').presence ||
      call_session.metadata&.dig('ai_voice', 'final_transcript')
    )
  end

  def voice_speaker_label(speaker)
    speaker.to_s.in?(%w[caller customer contact user]) ? 'Caller' : 'Assistant'
  end

  def captain_assistant
    @captain_assistant ||= begin
      assistant = inbox_captain_assistant || routing_policy&.captain_assistant
      assistant if assistant&.account_id == call_session.account_id
    end
  end

  def inbox_captain_assistant
    return unless conversation.inbox.respond_to?(:captain_assistant)

    conversation.inbox.captain_assistant
  end

  def routing_policy
    @routing_policy ||= call_session.number_binding&.routing_policy
  end

  def conversation
    @conversation ||= call_session.conversation
  end
end
