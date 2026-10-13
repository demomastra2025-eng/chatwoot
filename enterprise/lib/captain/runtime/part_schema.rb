# frozen_string_literal: true

# The structured result of one council part. The owner agent writes the final patient text of its part and reports how the
# part ended; whether an action was performed is NOT reported here but computed by code from the tool results of the run
# (see Council::PartRun), so a model can never claim an action by setting a field.
class Captain::Runtime::PartSchema < RubyLLM::Schema
  CUSTOMER_TEXT_DESCRIPTION = (
    'The final text of THIS part for the patient, in the patient\'s language. Say only what your tool results show. ' \
    'Empty string when there is nothing to say.'
  ).freeze
  STATUS_DESCRIPTION = (
    'Exactly one of: answered (the part is answered or its action is done), needs_information (you asked the patient, in one ' \
    'message, for everything still missing, and wait), out_of_scope (not your responsibility; no action was taken), ' \
    'unavailable (cannot be resolved now).'
  ).freeze
  QUESTIONS_DESCRIPTION = 'Every question for the patient that customer_text contains, word for word. Empty array when none.'
  SOURCES_DESCRIPTION = (
    'Where the facts came from: tool names, document titles, or "instructions". Empty array when customer_text states no fact.'
  ).freeze
  SUGGESTED_AGENT_DESCRIPTION = 'When out_of_scope: the exact name of the responsible agent from the list. Otherwise an empty string.'
  REASONING_DESCRIPTION = 'One short internal sentence on how the part ended. Never shown to the patient.'

  # patient_language comes first: the owner names the language before it writes the text. It is for the logs and for the editor
  # (see Captain::Runtime::CouncilEditor); the text is used as it is.
  string :patient_language, description: Captain::PatientLanguage::FIELD_DESCRIPTION
  string :customer_text, description: CUSTOMER_TEXT_DESCRIPTION
  string :status, description: STATUS_DESCRIPTION
  array :questions, of: :string, description: QUESTIONS_DESCRIPTION
  array :sources, of: :string, description: SOURCES_DESCRIPTION
  string :suggested_agent, description: SUGGESTED_AGENT_DESCRIPTION
  string :reasoning, description: REASONING_DESCRIPTION
end
