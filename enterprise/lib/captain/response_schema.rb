class Captain::ResponseSchema < RubyLLM::Schema
  string :response, description: 'The message to send to the user'
  string :reasoning, description: "Agent's thought process"
  string :handoff_message,
         description: 'Customer-facing handoff message when response is conversation_handoff and AI handoff message mode is enabled. Return an empty string when no handoff message should be sent.'
end
