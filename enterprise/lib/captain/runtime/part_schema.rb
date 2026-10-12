# frozen_string_literal: true

# The structured result of one council part. The owner agent writes the final customer text of its part and reports how the
# part ended; whether an action was performed is NOT reported here but computed by code from the tool results of the run
# (see Council::PartRun), so a model can never claim an action by setting a field.
class Captain::Runtime::PartSchema < RubyLLM::Schema
  CUSTOMER_TEXT_DESCRIPTION = (
    'The FINAL text for THIS part only, addressed to the customer and written in the customer language. Another editor only joins ' \
    'the texts of all parts into one message. Say only what your tool results show. Empty string when there is nothing to say.'
  ).freeze
  STATUS_DESCRIPTION = (
    'Exactly one of: answered (the part is answered or its action is done), needs_information (you asked the customer one precise ' \
    'question and wait for the answer), out_of_scope (the part is not your responsibility; no action was taken), unavailable ' \
    '(you cannot resolve the part now).'
  ).freeze
  QUESTIONS_DESCRIPTION = 'Every question for the customer that customer_text contains, word for word. Empty array when none.'
  SOURCES_DESCRIPTION = (
    'Where the facts of customer_text came from: tool names, document titles, or "instructions" for facts from your own ' \
    'instructions. Empty array when customer_text states no fact.'
  ).freeze
  SUGGESTED_AGENT_DESCRIPTION = 'When status is out_of_scope: the exact name of the responsible agent from the list. Otherwise an empty string.'
  REASONING_DESCRIPTION = 'One short internal sentence on how the part ended. Never shown to the customer.'

  string :customer_text, description: CUSTOMER_TEXT_DESCRIPTION
  string :status, description: STATUS_DESCRIPTION
  array :questions, of: :string, description: QUESTIONS_DESCRIPTION
  array :sources, of: :string, description: SOURCES_DESCRIPTION
  string :suggested_agent, description: SUGGESTED_AGENT_DESCRIPTION
  string :reasoning, description: REASONING_DESCRIPTION
end
