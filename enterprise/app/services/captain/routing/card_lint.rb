# frozen_string_literal: true

# Checks the competence cards of one clinic the way the router will read them. It runs in the prompt migration, in the evaluation
# harness and on demand; it never changes anything. Findings: { severity: 'error'|'warning', code:, assistant_ids:, message: }.
#   error   blank_card       a routable agent of a multi-agent clinic has no routing description: the router can never choose it
#   error   handoff_wording  a card still speaks of coordination, transfers or councils (the router decides that now)
#   warning shared_name      the same doctor appears on two cards (the requested service decides, but check it)
#   warning general_owner    zero or several cards cover general clinic questions (the first message of a bare greeting)
#   error   too_many_agents  more candidates than the router can ask about in one call
class Captain::Routing::CardLint
  # Words of the former agent-driven routing. A staff handoff step ("передай диалог старшему администратору через handoff") is the
  # agent's own procedure and is not matched: a transfer is matched only towards an agent, a colleague or a «named» unit. Nor is a
  # person of the clinic's business: a referral "по направлению координатора" (of an insurer) names a staff member, not an agent role.
  FORBIDDEN = [
    /(?<!направлению\s)координатор/i, /оркестратор/i, /orchestrator/i, /coordinator/i, /главн\p{L}*\s+(?:ии-)?(?:администратор|агент)/i,
    /transfer_to_\w*/i, /handoff_to_\w*/i, /plan_request/i, /консилиум/i, /\bcouncil\b/i,
    /(?:передай|переведи|перевести|передать|переключи)[^.\n]{0,60}(?:агент|коллег|«)/i,
    /transfer[^.\n]{0,40}(?:colleague|another agent|specialized agent|channel agent)/i
  ].freeze
  GENERAL_QUESTIONS = /общие вопросы|general (?:clinic )?questions/i
  # A surname with initials: "Асланов М.И.", "Князова Ж.Ж.", "Баева Л.В."
  NAME_WITH_INITIALS = /([А-ЯЁӘІҢҒҮҰҚӨҺA-Z][а-яёәіңғүұқөһa-z-]{2,})\s+[А-ЯЁӘІҢҒҮҰҚӨҺA-Z]\.\s?(?:[А-ЯЁӘІҢҒҮҰҚӨҺA-Z]\.)?/

  Finding = Struct.new(:severity, :code, :assistant_ids, :message, keyword_init: true) do
    def error? = severity == 'error'
    def to_h = super.compact
  end

  def self.call(candidates)
    new(candidates).call
  end

  # The forbidden words found in one text (a card or a whole prompt), for the migration lint.
  def self.forbidden_words(text)
    FORBIDDEN.filter_map { |pattern| text.to_s[pattern] }.map(&:downcase).uniq
  end

  def initialize(candidates)
    @candidates = Array(candidates)
  end

  def call
    return [] if @candidates.size < 2

    cards = @candidates.to_h { |candidate| [candidate.id, Captain::Routing::CompetenceCard.text(candidate, peers: peers_of(candidate))] }
    blank_cards(cards) + handoff_wording(cards) + shared_names(cards) + general_owner(cards) + many_candidates
  end

  private

  def peers_of(candidate)
    @candidates.reject { |peer| peer.id == candidate.id }
  end

  def blank_cards(cards)
    cards.select { |_id, card| card.blank? }.map do |id, _card|
      Finding.new(severity: 'error', code: 'blank_card', assistant_ids: [id],
                  message: "Agent #{id} has no routing description: the router can never choose it.")
    end
  end

  def handoff_wording(cards)
    cards.filter_map do |id, card|
      words = self.class.forbidden_words(card)
      next if words.empty?

      Finding.new(severity: 'error', code: 'handoff_wording', assistant_ids: [id],
                  message: "Agent #{id} card still speaks of coordination or transfers: #{words.join(', ')}.")
    end
  end

  def shared_names(cards)
    owners = Hash.new { |hash, key| hash[key] = [] }
    cards.each do |id, card|
      card.scan(NAME_WITH_INITIALS).flatten.map(&:downcase).uniq.each { |surname| owners[surname] << id }
    end
    owners.select { |_surname, ids| ids.uniq.size > 1 }.map do |surname, ids|
      Finding.new(severity: 'warning', code: 'shared_name', assistant_ids: ids.uniq.sort,
                  message: "The name #{surname.capitalize} is on the cards of agents #{ids.uniq.sort.join(', ')}.")
    end
  end

  def general_owner(cards)
    owners = cards.select { |_id, card| card.match?(GENERAL_QUESTIONS) }.keys
    return [] if owners.one?

    message = owners.empty? ? 'No card covers general clinic questions.' : "Several cards cover general clinic questions: #{owners.join(', ')}."
    [Finding.new(severity: 'warning', code: 'general_owner', assistant_ids: owners, message: message)]
  end

  def many_candidates
    limit = Captain::Runtime::DecisionRouter::Questions::MAX_AGENTS
    return [] if @candidates.size <= limit

    [Finding.new(severity: 'error', code: 'too_many_agents', assistant_ids: @candidates.map(&:id),
                 message: "#{@candidates.size} agents: the router asks about #{limit} agents at most in one call.")]
  end
end
