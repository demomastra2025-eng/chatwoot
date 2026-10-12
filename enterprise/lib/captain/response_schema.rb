class Captain::ResponseSchema < RubyLLM::Schema
  ARTIFACT_IDS_DESCRIPTION = (
    [
      'Opaque artifact candidate IDs from tool results to attach to the customer-facing message. ',
      'Return an empty array when no files should be attached.'
    ].join
  ).freeze
  # Kept in the schema (the structured output is strict and older runs may still carry it), but the agent is no longer
  # asked for a customer message: Captain::CustomerNoticeService writes the handoff text from the workspace settings.
  HANDOFF_MESSAGE_DESCRIPTION = 'Reserved. Always return an empty string; the handoff message is written elsewhere.'.freeze
  HANDOFF_REASON_DESCRIPTION = (
    [
      'Concise internal reason for opening the conversation / handing it to a human agent when ',
      'response is conversation_handoff. Return an empty string when no handoff is requested.'
    ].join
  ).freeze
  REASONING_DESCRIPTION = (
    [
      'Required non-empty, brief user-visible outcome rationale based on facts and tool results. ',
      'Do not include hidden chain-of-thought.'
    ].join
  ).freeze
  RESPONSE_MODE_DESCRIPTION = (
    'Exactly reply or suppress. Use reply when a customer-facing response is required, including a human handoff ' \
      '(call the handoff tool; the handoff value belongs in response, never here). Use suppress when the correct outcome ' \
      'is to send nothing, for example after a simple acknowledgement or when a human already answered.'
  ).freeze

  string :response, description: 'The message to send to the user'
  string :response_mode, description: RESPONSE_MODE_DESCRIPTION
  string :reasoning, description: REASONING_DESCRIPTION
  array :artifact_ids, of: :string, description: ARTIFACT_IDS_DESCRIPTION
  string :handoff_message, description: HANDOFF_MESSAGE_DESCRIPTION
  string :handoff_reason, description: HANDOFF_REASON_DESCRIPTION
end
