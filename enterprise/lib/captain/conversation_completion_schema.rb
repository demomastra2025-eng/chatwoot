class Captain::ConversationCompletionSchema < RubyLLM::Schema
  boolean :complete, description: 'Whether the conversation is complete and can be closed'
  string :reason, description: 'Brief explanation of why the conversation is complete or incomplete'
  # Kept for older runs; the customer notice is written by Captain::CustomerNoticeService, so this is always empty.
  string :message, description: 'Reserved. Always return an empty string; the customer notice is written elsewhere.'
end
