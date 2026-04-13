class Captain::ReplySuggestionService < Captain::BaseTaskService
  pattr_initialize [:account!, :conversation_display_id!, :user!]

  def perform
    make_api_call(
      model: task_model,
      messages: [
        { role: 'system', content: system_prompt },
        { role: 'user', content: formatted_conversation }
      ]
    )
  end

  private

  def system_prompt
    render_task_prompt('reply', prompt_variables)
  end

  def prompt_variables
    {
      'channel_type' => conversation.inbox.channel_type,
      'agent_name' => user.name,
      'agent_signature' => user.message_signature.presence,
      'has_search_tool' => false
    }
  end

  def formatted_conversation
    LlmFormatter::ConversationLlmFormatter.new(conversation).format(token_limit: TOKEN_LIMIT)
  end

  def event_name
    'reply_suggestion'
  end

  def task_moderation_stages
    [:output]
  end
end

Captain::ReplySuggestionService.prepend_mod_with('Captain::ReplySuggestionService')
