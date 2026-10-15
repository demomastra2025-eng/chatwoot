# frozen_string_literal: true

# The decision model supplies one language hint for an entire agent run.
module Captain::PatientLanguage
  NAMES = { 'ru' => 'Russian', 'kk' => 'Kazakh', 'en' => 'English' }.freeze
  RULE = "Reply in the patient's language."
  FIELD_DESCRIPTION = (
    'The language for this reply: Kazakh, Russian or English. When the "# Now" section of the system prompt contains a ' \
    '"Patient language: <Language>. Reply in <Language>." line, you MUST set patient_language to that exact <Language> and write ' \
    'the entire reply in that language — even after calling tools or when earlier turns or tool results are in another language. ' \
    'When no "Patient language:" line is present, use the language of the latest user message (a bare "да"/"ок" keeps the language ' \
    'of the preceding turn; in Kazakh, repeated enclitic particles before the final negation word mean "neither ... nor ... none", ' \
    'not Russian "yes").'
  ).freeze

  def self.line(code)
    name = NAMES[code]
    "Patient language: #{name}. Reply in #{name}." if name
  end
end
