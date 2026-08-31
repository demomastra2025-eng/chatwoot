class Captain::ConversationCompletionSchema < RubyLLM::Schema
  MESSAGE_DESCRIPTION = [
    'Customer-facing message to send when AI-generated resolution or handoff message mode is enabled.',
    'Return an empty string when no message should be sent.'
  ].join(' ').freeze

  boolean :complete, description: 'Whether the conversation is complete and can be closed'
  string :reason, description: 'Brief explanation of why the conversation is complete or incomplete'
  string :status_reason,
         description: 'Exact configured stable completion or handoff reason ID. Return an empty string when no options are configured.'
  string :message,
         description: MESSAGE_DESCRIPTION
end
