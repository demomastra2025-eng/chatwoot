# frozen_string_literal: true

class Captain::Runtime::ProviderRefusalFallback
  CANDIDATE_MODELS = %w[
    google/gemini-3.8-flash
    anthropic/claude-haiku-5.5
    google/gemini-3.1-flash-lite
    openai/gpt-5.4-mini
  ].freeze
  VENDOR_THINKING_KEYS = %i[thinking thinking_signature reasoning reasoning_details native_reasoning].freeze

  class << self
    def effective_model(session)
      session[:model_override].presence || session[:current_agent].model
    end

    def next_model(session)
      return if session[:provider_refusal_retried]

      current_model = effective_model(session).to_s
      current_vendor = vendor_for(current_model)
      CANDIDATE_MODELS.find do |candidate|
        eligible_candidate?(candidate, current_model: current_model, current_vendor: current_vendor, session: session)
      end
    end

    def preserve_tool_progress!(session, old_chat, initial_count)
      return false unless tool_messages_added?(old_chat, initial_count)

      extracted = Captain::Runtime::MessageExtractor.extract_messages(old_chat, session[:current_agent])
      session[:context_wrapper].context[:conversation_history] = strip_vendor_thinking(extracted)
      true
    end

    def publish_fallback_event(session:, from_model:, to_model:, error:)
      Llm::EventBus.publish(
        'run.provider_refusal_fallback',
        agent_name: session[:current_agent]&.name,
        from_model: from_model,
        to_model: to_model,
        turn: session[:current_turn],
        reason: error.message
      )
    end

    def vendor_for(model)
      text = model.to_s.strip.downcase
      return text.split('/', 2).first.presence if text.include?('/')
      return 'google' if text.start_with?('gemini-')
      return 'anthropic' if text.start_with?('claude-')
      return 'openai' if text.match?(/\A(?:gpt-|o[134]-)/)

      nil
    end

    private

    def eligible_candidate?(candidate, current_model:, current_vendor:, session:)
      return false if candidate == current_model
      return false if current_vendor.present? && vendor_for(candidate) == current_vendor

      supported_for_session?(candidate, session)
    end

    def supported_for_session?(candidate, session)
      agent = session[:current_agent]
      tools = session[:finalization_only] ? [] : agent.tools
      Llm::CapabilityPolicy.ensure_chat_features_supported!(
        model: candidate,
        schema: agent.response_schema,
        tools: tools,
        account: session[:account]
      )
      Llm::CapabilityPolicy.ensure_input_supported!(
        model: candidate,
        content: session[:input],
        account: session[:account]
      )
      true
    rescue Llm::CapabilityPolicy::UnsupportedCapabilityError
      false
    end

    def tool_messages_added?(chat, initial_count)
      return false unless chat.respond_to?(:messages) && chat.messages.is_a?(Array)

      Array(chat.messages[initial_count.to_i..]).any? do |message|
        message.respond_to?(:role) && message.role.to_s == 'tool'
      end
    end

    def strip_vendor_thinking(messages)
      Array(messages).map do |message|
        next message unless message.is_a?(Hash)

        cleaned = message.dup
        VENDOR_THINKING_KEYS.each do |key|
          cleaned.delete(key)
          cleaned.delete(key.to_s)
        end
        cleaned
      end
    end
  end
end
