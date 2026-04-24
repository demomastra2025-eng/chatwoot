class Captain::ConversationCompletionSchema < RubyLLM::Schema
  boolean :complete, description: 'Whether the conversation is complete and can be closed'
  string :reason, description: 'Brief explanation of why the conversation is complete or incomplete'
  string :message, description: 'Optional customer-facing message to send when AI-generated resolution or handoff message mode is enabled',
                   required: false
end
