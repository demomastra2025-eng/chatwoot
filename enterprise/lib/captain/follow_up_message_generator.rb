# frozen_string_literal: true

class Captain::FollowUpMessageGenerator < Captain::BaseTaskService
  RESPONSE_SCHEMA = Captain::FollowUpMessageSchema
  MAX_MESSAGE_LENGTH = 2_000
  MAX_PROMPT_LENGTH = 4_000
  MAX_OBJECTIVE_LENGTH = 1_000

  pattr_initialize [
    :account!,
    :assistant!,
    :messages!,
    :settings!,
    :step!,
    { conversation_display_id: nil },
    { scenario: nil },
    { step_index: 0 },
    { model: nil }
  ]

  def perform
    validation_error = input_validation_error
    return failed_result(validation_error) if validation_error

    generate_message
  rescue StandardError => e
    Rails.logger.warn("[CAPTAIN][FollowUpMessageGenerator] Generation failed: #{e.class.name}")
    failed_result(e.class.name)
  end

  private

  def input_validation_error
    return 'Follow-up prompt is missing' if follow_up_prompt.blank?
    return 'Follow-up prompt is too long' if follow_up_prompt.length > MAX_PROMPT_LENGTH
    return 'Follow-up objective is missing' if step_objective.blank?
    return 'Follow-up objective is too long' if step_objective.length > MAX_OBJECTIVE_LENGTH
    return 'Conversation context is missing' if normalized_messages.blank?
  end

  def generate_message
    response = make_api_call(
      model: resolved_model,
      messages: request_messages,
      schema: RESPONSE_SCHEMA
    )
    return failed_result('provider_unavailable') if response[:error].present?

    payload = response[:message].to_h.with_indifferent_access
    message = payload[:message].to_s.strip
    return failed_result('AI returned a blank follow-up message') if message.blank?
    return failed_result('AI returned an oversized follow-up message') if message.length > MAX_MESSAGE_LENGTH

    {
      generated: true,
      message: message,
      reason: payload[:reason].to_s.strip,
      usage: response[:usage]
    }
  end

  def request_messages
    [
      { role: 'system', content: system_prompt },
      { role: 'user', content: generation_context }
    ]
  end

  def system_prompt
    render_task_prompt(
      'follow_up_message',
      assistant_name: assistant.name,
      assistant_instruction: assistant.system_instruction,
      scenario_title: scenario&.title,
      scenario_instruction: scenario&.instruction,
      response_guidelines: Array(assistant.response_guidelines).join("\n"),
      guardrails: Array(assistant.guardrails).join("\n"),
      follow_up_prompt: follow_up_prompt,
      step_objective: step_objective
    )
  end

  def generation_context
    [
      "Follow-up step: #{step_index.to_i + 1}",
      "Current time: #{Time.current.iso8601}",
      "Allowed business context (JSON):\n#{JSON.generate(prompt_context)}",
      "Conversation history:\n#{formatted_history}"
    ].join("\n\n")
  end

  def prompt_context
    runtime_state = Captain::ContextFields.runtime_state_for(
      account: account,
      conversation: conversation,
      channel_type: conversation&.inbox&.channel_type,
      assistant: assistant
    )
    assistant.prompt_context_state(runtime_state, field_ids: referenced_context_field_ids)
  end

  def referenced_context_field_ids
    prompt_text = [
      assistant.system_instruction,
      Array(assistant.response_guidelines),
      Array(assistant.guardrails),
      scenario&.instruction,
      follow_up_prompt,
      step_objective
    ].flatten.compact.join("\n")
    Captain::ContextFields.extract_field_ids_from_text(prompt_text)
  end

  def formatted_history
    normalized_messages.map do |message|
      sender = message[:role] == 'user' ? 'Customer' : 'Assistant'
      "#{sender}: #{message[:content]}"
    end.join("\n")
  end

  def normalized_messages
    @normalized_messages ||= Array(messages).last(30).filter_map do |message|
      payload = message.to_h.with_indifferent_access
      content = payload[:content].to_s.strip
      next if content.blank?

      {
        role: payload[:role].to_s == 'user' ? 'user' : 'assistant',
        content: content
      }
    end
  end

  def follow_up_prompt
    settings.to_h.with_indifferent_access[:prompt].to_s.strip
  end

  def step_objective
    step.to_h.with_indifferent_access[:objective].to_s.strip
  end

  def resolved_model
    model.presence || assistant.config.to_h['model'].presence || task_model
  end

  def failed_result(reason)
    { generated: false, error: reason.to_s.presence || 'Follow-up generation failed' }
  end

  def event_name
    'captain.follow_up_message'
  end

  def task_moderation_stages
    %i[input output]
  end

  def build_follow_up_context?
    false
  end

  def llm_feature_key
    'assistant'
  end
end

Captain::FollowUpMessageGenerator.prepend_mod_with('Captain::FollowUpMessageGenerator')
