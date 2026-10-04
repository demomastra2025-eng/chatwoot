class Captain::FollowUpMessageSchema < RubyLLM::Schema
  string :message,
         description: 'One concise customer-facing follow-up message in the same language as the conversation'
  string :reason, description: 'Brief internal explanation of how the message supports the configured objective'
end
