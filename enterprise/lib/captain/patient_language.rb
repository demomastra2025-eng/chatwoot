# frozen_string_literal: true

# The one language rule of the agents. The platform rules (prompts/assistant.liquid), the owner of a council part and the council
# editor all write for the patient in the language this rule names, and the structured results carry the language the model
# decided on (patient_language, written before the reply text) so that the language is chosen before the words are.
module Captain::PatientLanguage
  # The sentence that names the language. assistant.liquid carries it as the start of its reply-language rule.
  RULE = "Reply in the patient's language: the language of most of the patient's words in the conversation, in any alphabet " \
         '(Kazakh may be written in Russian or Latin letters). Keep it when a message contains words of another language.'

  FIELD_DESCRIPTION = "The patient's language per the platform rule, e.g. Kazakh, Russian, English; decide it before writing the reply."
end
