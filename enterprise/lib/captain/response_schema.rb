class Captain::ResponseSchema < RubyLLM::Schema
  ARTIFACT_IDS_DESCRIPTION = (
    [
      'Opaque artifact candidate IDs from tool results to attach to the customer-facing message. ',
      'Return an empty array when no files should be attached.'
    ].join
  ).freeze
  HANDOFF_MESSAGE_DESCRIPTION = (
    [
      'Customer-facing handoff message when response is conversation_handoff and ',
      'AI handoff message mode is enabled. Return an empty string when no handoff message should be sent.'
    ].join
  ).freeze
  REASONING_DESCRIPTION = (
    [
      'Required non-empty, brief user-visible outcome rationale based on facts and tool results. ',
      'Do not include hidden chain-of-thought.'
    ].join
  ).freeze

  string :response, description: 'The message to send to the user'
  string :reasoning, description: REASONING_DESCRIPTION
  array :artifact_ids, of: :string, description: ARTIFACT_IDS_DESCRIPTION
  string :handoff_message, description: HANDOFF_MESSAGE_DESCRIPTION
end
