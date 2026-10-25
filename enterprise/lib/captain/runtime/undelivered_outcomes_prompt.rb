# frozen_string_literal: true

# What specialists did in an earlier run whose reply never reached the patient (the reply was dropped because a newer message
# arrived): the agent that answers this turn mentions it. Appended to the per-request part of the prompt of every agent run that
# is not a council part, and only when there is something in it.
module Captain::Runtime::UndeliveredOutcomesPrompt
  MENTION_IT = 'Mention it in your reply.'
  FRAGMENT_LIMIT = 200

  module_function

  def render(context)
    outcomes = Captain::Runtime::PartRegistry.undelivered_outcomes(context[:parts]).map { |part| outcome_text(part) }
    return '' if outcomes.empty?

    ['# Done, not yet told to the patient (data)', *outcomes.map { |text| "- #{text} #{MENTION_IT}" }].join("\n")
  end

  def outcome_text(part)
    fragment = JSON.generate(part['fragment'].to_s.squish.first(FRAGMENT_LIMIT))
    text = part['summary'].to_s.squish.presence || "An action was done for the request #{fragment}"
    text.match?(/[.!?…]\z/) ? text : "#{text}."
  end
end
