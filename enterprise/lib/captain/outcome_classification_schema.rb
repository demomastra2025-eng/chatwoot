# frozen_string_literal: true

class Captain::OutcomeClassificationSchema < RubyLLM::Schema
  string :reason_id, description: 'One ID from the supplied allowed reasons, or other when evidence is insufficient.'
  string :explanation, description: 'One short factual sentence about the outcome; no private reasoning or personal identifiers.'
  boolean :needs_more_context, description: 'True only when the initial fragment is insufficient. At most one longer fragment is available.'
end
