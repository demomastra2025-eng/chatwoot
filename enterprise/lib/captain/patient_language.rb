# frozen_string_literal: true

# The decision model supplies one language hint for an entire agent run.
module Captain::PatientLanguage
  NAMES = { 'ru' => 'Russian', 'kk' => 'Kazakh', 'en' => 'English' }.freeze
  RULE = "Reply in the patient's language."
  FIELD_DESCRIPTION = 'The language used for the patient reply: Kazakh, Russian or English. You MUST follow the "Patient language:" line ' \
                      'in "# Now" when present (for example, if "# Now" says "Patient language: Kazakh. Reply in Kazakh.", set ' \
                      'patient_language to "Kazakh" and write the entire reply in Kazakh, even when "# Clinic instructions", tool results, ' \
                      'or earlier turns are in Russian); otherwise use the language of the latest patient message (a bare one-word ' \
                      'confirmation keeps the language of the preceding turn; in Kazakh, repeated particles "да/де/та/те" before a final ' \
                      'negation word "жоқ/емес" mean "neither ... nor ... none", not affirmative).'

  def self.line(code)
    name = NAMES[code]
    "Patient language: #{name}. Reply in #{name}." if name
  end
end
