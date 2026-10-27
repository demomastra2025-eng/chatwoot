# The output of the agent when it drafts a reply suggestion for the clinic operator (a live conversation keeps Captain::ResponseSchema).
# Besides the draft it can say that no reply is needed, or that a staff member must answer, and in both cases it tells the operator why in
# operator_note: the operator reads it as a plain text above the reply box, the patient never sees it.
class Captain::SuggestionResponseSchema < RubyLLM::Schema
  RESPONSE_MODES = %w[reply suppress human].freeze
  RESPONSE_MODE_DESCRIPTION = 'reply - a draft reply for the operator to send; suppress - no reply is needed (the patient wrote only ' \
                              'thanks, ok or an emoji, or staff already answered); human - a staff member must answer instead of the AI ' \
                              '(the clinic data has no answer, or it needs a staff decision: a medical judgement, a complaint, a refund, ' \
                              'an exception to the clinic rules).'.freeze
  OPERATOR_NOTE_DESCRIPTION = 'For the clinic operator, never the patient. With suppress: why no reply is needed. With human: why a ' \
                              'staff member must answer and what is missing. One or two short sentences in the operator language ' \
                              'named in the platform rules. With reply: an empty string, unless the draft leaves a part of the ' \
                              'request to staff (then name that part).'.freeze

  string :patient_language, description: Captain::PatientLanguage::FIELD_DESCRIPTION
  string :response_mode, enum: RESPONSE_MODES, description: RESPONSE_MODE_DESCRIPTION
  string :response, description: "#{Captain::ResponseSchema::RESPONSE_DESCRIPTION} Empty with suppress or human."
  string :operator_note, description: OPERATOR_NOTE_DESCRIPTION
  string :reasoning, description: Captain::ResponseSchema::REASONING_DESCRIPTION
  array :artifact_ids, of: :string, description: Captain::ResponseSchema::ARTIFACT_IDS_DESCRIPTION
end
