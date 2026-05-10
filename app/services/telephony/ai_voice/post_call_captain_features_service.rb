class Telephony::AiVoice::PostCallCaptainFeaturesService
  FEATURE_MEMORY = 'memory'.freeze
  FEATURE_FAQ = 'faq'.freeze

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
      Captain::Llm::ContactNotesService.new(captain_assistant, conversation).generate_and_update_notes
    end
  end

  def run_faq_feature
    run_feature(FEATURE_FAQ) do
      Captain::Llm::ConversationFaqService.new(captain_assistant, conversation).generate_and_deduplicate
    end
  end

  def run_feature(feature_name)
    return if feature_completed?(feature_name)

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

  def feature_completed?(feature_name)
    call_session.reload.metadata&.dig('ai_voice', 'post_call_captain_features', feature_name, 'completed_at').present?
  end

  def record_feature_result!(feature_name, attrs)
    call_session.with_lock do
      metadata = (call_session.reload.metadata || {}).deep_dup
      ai_voice = metadata['ai_voice'] ||= {}
      features = ai_voice['post_call_captain_features'] ||= {}
      features[feature_name] = (features[feature_name] || {}).merge(
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
    call_session.metadata&.dig('ai_voice', 'transcript', 'final_items').present? ||
      call_session.metadata&.dig('ai_voice', 'final_transcript').present? ||
      conversation.messages.voice_calls.any? { |message| voice_message_transcript_present?(message) }
  end

  def voice_message_transcript_present?(message)
    data = message.content_attributes.to_h['data'] || {}
    data['transcript'].present? || Array(data['transcript_items']).any? { |item| item.to_h['text'].present? }
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
