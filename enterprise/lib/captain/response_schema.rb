class Captain::ResponseSchema < RubyLLM::Schema
  # The model writes the reply and nothing else: a handoff goes through the handoff tool, and its reason and the notice to the
  # customer are written by the platform (Captain::CustomerNoticeService), so the model has no handoff fields.
  # patient_language comes first: the model names the language before it writes the reply. It is for the logs; the reply is
  # delivered as it is.
  # response_mode is an enum, so the provider offers the model these two values and nothing else.
  RESPONSE_MODES = %w[reply suppress].freeze
  RESPONSE_DESCRIPTION = 'Text for the patient.'.freeze
  RESPONSE_MODE_DESCRIPTION = "reply - send the reply; suppress - send nothing (the patient wrote only an 'ok', or staff already replied).".freeze
  REASONING_DESCRIPTION = 'One short phrase for the log: what the reply is based on. The patient never sees it.'.freeze
  ARTIFACT_IDS_DESCRIPTION = 'IDs of files from tool results to attach; otherwise an empty list.'.freeze

  string :patient_language, description: Captain::PatientLanguage::FIELD_DESCRIPTION
  string :response, description: RESPONSE_DESCRIPTION
  string :response_mode, enum: RESPONSE_MODES, description: RESPONSE_MODE_DESCRIPTION
  string :reasoning, description: REASONING_DESCRIPTION
  array :artifact_ids, of: :string, description: ARTIFACT_IDS_DESCRIPTION
end
