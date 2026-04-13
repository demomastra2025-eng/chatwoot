class Captain::RewriteService < Captain::BaseTaskService
  pattr_initialize [:account!, :content!, :operation!, { conversation_display_id: nil }]

  TONE_OPERATIONS = %i[casual professional friendly confident straightforward].freeze
  ALLOWED_OPERATIONS = (%i[fix_spelling_grammar improve] + TONE_OPERATIONS).freeze

  def perform
    operation_sym = operation.to_sym
    raise ArgumentError, "Invalid operation: #{operation}" unless ALLOWED_OPERATIONS.include?(operation_sym)

    send(operation_sym)
  end

  TONE_OPERATIONS.each do |tone|
    define_method(tone) do
      call_llm_with_prompt(tone_rewrite_prompt(tone.to_s))
    end
  end

  private

  def fix_spelling_grammar
    call_llm_with_prompt(render_task_prompt('fix_spelling_grammar'))
  end

  def improve
    system_prompt = render_task_prompt(
      'improve',
      conversation_context: conversation.to_llm_text(include_contact_details: true),
      draft_message: content
    )

    call_llm_with_prompt(system_prompt, content)
  end

  def call_llm_with_prompt(system_content, user_content = content)
    make_api_call(
      model: task_model,
      messages: [
        { role: 'system', content: system_content },
        { role: 'user', content: user_content }
      ]
    )
  end

  def tone_rewrite_prompt(tone)
    render_task_prompt('tone_rewrite', tone: tone)
  end

  def event_name
    operation
  end

  def task_moderation_stages
    [:output]
  end
end
