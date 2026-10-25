# frozen_string_literal: true

# Checks one agent's prompt texts for the world where the router decides who answers: no coordination, transfer or council
# vocabulary, no names of the other agents of the clinic, a routing description (the competence card) that exists and fits.
# Findings: { severity: 'error'|'warning', field:, code:, message: }.
module Captain::PromptMigration::Lint
  CARD_LIMIT = Concerns::CaptainAgentRouting::ROUTING_DESCRIPTION_MAX_LENGTH
  # A name shorter than this is too generic to look for in a prompt.
  MIN_NAME_LENGTH = 6

  module_function

  # texts: { description:, routing_description: }; others: the other agents of the account ([[id, name]]); routable: whether
  # the router can choose this agent (an internal assistant needs no card).
  def call(texts, others: [], routable: true)
    findings = []
    { 'description' => texts[:description], 'routing_description' => texts[:routing_description] }.each do |field, text|
      findings.concat(vocabulary(field, text))
      findings.concat(other_names(field, text, others))
    end
    findings.concat(card(texts[:routing_description])) if routable
    findings
  end

  def vocabulary(field, text)
    words = Captain::Routing::CardLint.forbidden_words(text)
    return [] if words.empty?

    [{ severity: 'error', field: field, code: 'handoff_wording', message: "speaks of coordination or transfers: #{words.join(', ')}" }]
  end

  def other_names(field, text, others)
    named = others.select { |(_id, name)| name.to_s.squish.length >= MIN_NAME_LENGTH && text.to_s.include?(name.to_s.squish) }
    return [] if named.empty?

    [{ severity: 'error', field: field, code: 'other_agent_name',
       message: "names other agents of the clinic: #{named.map { |(id, name)| "#{id} #{name.to_s.squish}" }.join('; ')}" }]
  end

  def card(text)
    return [{ severity: 'error', field: 'routing_description', code: 'blank_card', message: 'no routing description' }] if text.to_s.strip.blank?
    return [] if text.to_s.length <= Captain::Routing::CompetenceCard::MAX_LENGTH

    severity = text.to_s.length > CARD_LIMIT ? 'error' : 'warning'
    [{ severity: severity, field: 'routing_description', code: 'card_length',
       message: "#{text.to_s.length} characters (the router reads #{Captain::Routing::CompetenceCard::MAX_LENGTH})" }]
  end
end
