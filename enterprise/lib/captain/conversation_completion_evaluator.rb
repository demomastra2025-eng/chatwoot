# frozen_string_literal: true

class Captain::ConversationCompletionEvaluator < Captain::BaseTaskService
  RESPONSE_SCHEMA = Captain::ConversationCompletionSchema

  pattr_initialize [:account!, :messages!, { conversation_display_id: nil }, { model: nil }]

  def perform
    content = format_messages_as_string
    return default_incomplete_response('No messages found') if content.blank?

    response = make_api_call(
      model: resolved_model,
      messages: [
        { role: 'system', content: render_task_prompt('conversation_completion') },
        { role: 'user', content: content }
      ],
      schema: RESPONSE_SCHEMA
    )

    return default_incomplete_response(response[:error]) if response[:error].present?

    parse_response(response[:message])
  end

  private

  def format_messages_as_string
    normalize_messages(messages).map do |msg|
      sender_type = msg[:role] == 'user' ? 'Customer' : 'Assistant'
      "#{sender_type}: #{msg[:content]}"
    end.join("\n")
  end

  def normalize_messages(raw_messages)
    Array(raw_messages).filter_map do |message|
      payload = message.to_h.with_indifferent_access
      content = payload[:content].to_s
      next if content.blank?

      {
        role: payload[:role].to_s == 'user' ? 'user' : 'assistant',
        content: content
      }
    end
  end

  def parse_response(message)
    return default_incomplete_response('Invalid response format') unless message.is_a?(Hash)

    result = {
      complete: message['complete'] == true || message[:complete] == true,
      reason: message['reason'] || message[:reason] || 'No reason provided',
      evaluated: true
    }
    generated_message = message['message'] || message[:message]
    result[:message] = generated_message if generated_message.present?
    result
  end

  def default_incomplete_response(reason)
    { complete: false, reason: reason, evaluated: false }
  end

  # Prefer the system API key over the account's OpenAI hook key.
  # This is an internal operational evaluation, not a customer-triggered feature,
  # so it should not consume the customer's OpenAI credits on hosted platforms.
  # Falls back to the account hook key when no system key exists.
  def api_key(_provider_name = model_provider)
    @api_key ||= system_api_key.presence || openai_hook&.settings&.dig('api_key')
  end

  def resolved_model
    model.presence || task_model
  end

  def event_name
    'captain.conversation_completion'
  end

  def build_follow_up_context?
    false
  end

  def llm_feature_key
    'assistant'
  end
end

Captain::ConversationCompletionEvaluator.prepend_mod_with('Captain::ConversationCompletionEvaluator')
