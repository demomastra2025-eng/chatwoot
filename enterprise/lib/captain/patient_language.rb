# frozen_string_literal: true

# The decision model supplies one language hint for an entire agent run.
module Captain::PatientLanguage
  NAMES = { 'ru' => 'Russian', 'kk' => 'Kazakh', 'en' => 'English' }.freeze
  RULE = "Reply in the patient's language."
  FIELD_DESCRIPTION = 'The language used for the patient reply, e.g. Kazakh, Russian or English.'

  def self.line(code)
    name = NAMES[code]
    "Patient language: #{name}. Reply in #{name}." if name
  end
end
