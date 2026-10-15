# frozen_string_literal: true

# The decision model supplies one language hint for an entire agent run.
module Captain::PatientLanguage
  NAMES = { 'ru' => 'Russian', 'kk' => 'Kazakh', 'en' => 'English' }.freeze
  RULE = "Reply in the patient's language."
  FIELD_DESCRIPTION = (
    'The language used for the patient reply: Kazakh, Russian or English. Follow the "Patient language:" line in "# Now" ' \
    'when present, even when tool results or earlier turns use another language; otherwise use the language of the latest ' \
    'patient message (a bare one-word confirmation keeps the language of the preceding turn; in Kazakh, repeated particles ' \
    '"да/де/та/те" before a final negation word "жоқ/емес" mean "neither ... nor ... none", not affirmative).'
  ).freeze

  def self.line(code)
    name = NAMES[code]
    "Patient language: #{name}. Reply in #{name}." if name
  end
end
