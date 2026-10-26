# frozen_string_literal: true

class Captain::Runtime::PartSchema < RubyLLM::Schema
  LANGUAGE_DESCRIPTION = Captain::PatientLanguage::FIELD_DESCRIPTION
  CUSTOMER_TEXT_DESCRIPTION = 'The final text for this part only, addressed to the patient politely, one to three short ' \
                              'sentences in the patient\'s language, no greeting, no markdown. When a question is needed, ' \
                              'end with that question. For a named person other than the writer (a child, a relative), ' \
                              'name that person in the text. Leave blank only when this part needs no text for the patient.'
  QUESTIONS_DESCRIPTION = 'Every question that customer_text contains, word for word; empty when it contains no question.'
  # no_reply_needed: the part needs no answer (only thanks, ok, an emoji or a greeting); it is not handed to staff.
  NO_REPLY_STATUS = 'no_reply_needed'
  STATUSES = %w[answered needs_information out_of_scope unavailable no_reply_needed].freeze
  STATUS_DESCRIPTION = 'answered (answered or action done), needs_information (you asked the patient, in one message, for ' \
                       'everything still missing, and wait), out_of_scope (another agent handles this), unavailable ' \
                       '(cannot be resolved now, or a staff-only request such as a complaint, certificate or test result ' \
                       'already has all required details), or no_reply_needed (only thanks, ok, an emoji or a greeting: ' \
                       'customer_text stays empty).'

  string :patient_language, description: LANGUAGE_DESCRIPTION
  string :customer_text, description: CUSTOMER_TEXT_DESCRIPTION
  string :status, enum: STATUSES, description: STATUS_DESCRIPTION
  array :questions, of: :string, description: QUESTIONS_DESCRIPTION
  array :sources, of: :string, description: 'Tool names, document titles, or "instructions" for facts from your own instructions.'
  string :reasoning, description: 'Internal reasoning, never shown to the patient.'
end
