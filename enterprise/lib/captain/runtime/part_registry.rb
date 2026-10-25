# frozen_string_literal: true

# The durable parts of a conversation: what each agent of a council took on, where it stands and what the patient was told about
# it. The parts belong to the conversation, not to its current agent. A council is accepted here once per patient request, with
# exactly the participants the router chose (see Captain::Runtime::TurnDispatcher and Captain::Runtime::CouncilPlan).
class Captain::Runtime::PartRegistry
  MAX_COUNCIL_PARTS = 3
  SUMMARY_LIMIT = 600
  # The sentence told to the customer for a part stays whole up to the length of one message.
  REPLY_TEXT_LIMIT = 3000
  STATES = %w[open answered waiting_customer done failed unknown].freeze
  OPEN_STATES = %w[open waiting_customer unknown].freeze
  # The one mode of a new plan. A plan stored with a former mode is still replayed as it was saved, never re-validated.
  MODES = %w[council].freeze
  RELATIONS = %w[independent conditional depends_on].freeze
  PREREQUISITE_RELATIONS = %w[depends_on conditional].freeze
  LINK_ACTIONS = %w[new answer correction cancellation].freeze
  CONTINUATION_ACTIONS = %w[answer correction cancellation].freeze
  ABSORBABLE_STATES = %w[open waiting_customer].freeze
  ABSORBED_SUMMARY = 'continued in the conversation'

  # What was sent to the customer for THIS version of the part. A new version starts from the deliveries of the one before it, so
  # each delivery records the version it reported (see ResponseBuilderJob#record_part_delivery); one written before versions were
  # recorded counts for every version.
  def self.deliveries_of_version(part)
    Array(part['delivered']).select { |delivery| delivery['version'].nil? || delivery['version'].to_i == part['version'].to_i }
  end

  # Actions a specialist performed in an earlier run whose reply never reached the customer (the reply was dropped because a
  # newer message arrived): the next reply must tell the customer. The action of a follow-up version (the customer answered, the
  # version booked) is reported by a delivery of that version, not by the question that an earlier version delivered.
  def self.undelivered_outcomes(parts)
    Array(parts).select { |part| part['acted'] == true && part['cancelled'] != true && deliveries_of_version(part).empty? }
  end

  # The number a part is listed with (#3) and linked by: its position among the stored parts of the conversation. The list only
  # grows (a part is replaced in place), so a number does not change while the part is open.
  def self.number_of(parts, part_id)
    index = Array(parts).index { |item| item['id'] == part_id }
    index + 1 if index
  end

  # The exact id of the stored part with that number ("3" or "#3"); the reference itself when it points at no stored part.
  def self.part_id_for(parts, reference)
    text = reference.to_s.strip
    number = text.delete_prefix('#')[/\A\d+\z/]
    return text if number.nil? || number.to_i < 1

    Array(parts)[number.to_i - 1]&.dig('id') || text
  end

  def initialize(context)
    @context = context
  end

  # parts: the parts of a council, each with its integer executor_agent_id, in the order of the message; a part linked to an open
  # part of the same agent (link_part_id) continues it as its next version. The optional block checks the parts before anything
  # is stored (see Captain::Runtime::CouncilPlan). A plan that was already accepted for this request (a retried job) is replayed
  # as it was saved.
  def accept!(mode:, parts:)
    scope = Captain::Runtime::OperationScope.request(@context)
    saved = @context[:agent_session]&.read
    return replay(saved) if saved && saved['last_part_plan_scope'] == scope

    validate_council!(mode, parts)
    parts = yield(parts) if block_given?
    previous = Array(@context[:parts])
    normalized = parts.map { |raw| normalize_part(raw, previous) }
    link_prerequisites!(normalized)

    plan = { mode: mode, parts: normalized, clarification: '' }
    persist_plan(plan, scope)
    @context[:part_plan] = plan
    @context[:part_plan_accepted] = true
    @context[:part_plan]
  end

  def update!(part_id, attributes)
    persist([changed_part(part_id, attributes)])
  end

  # The agent answers the turn alone (the router kept it or routed to it): the questions it left open in a council are continued
  # in the conversation, so they are no longer open parts. Its parts that acted keep their record.
  def absorb_open_parts!(agent_id)
    open = Array(@context[:parts]).select do |part|
      part['executor_agent_id'].to_i == agent_id.to_i && ABSORBABLE_STATES.include?(part['state']) && part['handed_to_staff'] != true
    end
    return if open.empty?

    persist(open.map { |part| part.merge('state' => 'answered', 'summary' => part['summary'].presence || ABSORBED_SUMMARY) })
  end

  # The result of a part, written by the council. It goes straight to the stored part and merges ONLY the keys it is given, so
  # that nothing written meanwhile (for example deliveries) is lost. It does not require the run to be current: the action of a
  # part (a booking) has already happened, and it must be on record even when the reply is later dropped. A council part runs
  # with a context that has neither the parts nor the graph, so nothing here may depend on them.
  #
  # summary is what the tools of the part returned, for the model and for staff. reply_text is the sentence the customer is told
  # for the part: a retried request replays it. technical is the failure that stopped the part (names and codes only), so that the
  # replay hands the conversation to staff as the first attempt did.
  def record_result!(part_id, state: nil, summary: nil, missing_fields: nil, executor_agent_id: nil, acted: nil, reply_text: nil, technical: nil,
                     handed_to_staff: nil)
    raise ArgumentError, 'Invalid part state' if state && !STATES.include?(state)

    changes = { 'state' => state, 'executor_agent_id' => executor_agent_id, 'acted' => acted, 'handed_to_staff' => handed_to_staff }.compact
    changes['summary'] = summary.to_s.first(SUMMARY_LIMIT) unless summary.nil?
    changes['reply_text'] = reply_text.to_s.first(REPLY_TEXT_LIMIT) unless reply_text.nil?
    changes['technical'] = technical.to_h.deep_stringify_keys if technical.present?
    changes['missing_fields'] = Array(missing_fields) unless missing_fields.nil?
    session = @context[:agent_session]
    return merge_into_context!(part_id, changes) unless session

    session.record do |data|
      stored = Array(data['parts']).find { |item| item['id'] == part_id }
      raise ArgumentError, 'Part not found' unless stored

      stored.merge!(changes)
      @context[:parts] = Array(data['parts']).deep_dup
    end
  end

  private

  def validate_council!(mode, parts)
    raise ArgumentError, 'Invalid plan mode' unless MODES.include?(mode)
    # The participants (two or three different agents) are checked against the decision (CouncilPlan); a stored part can be continued alone.
    raise ArgumentError, 'A council has one to three parts' unless parts.is_a?(Array) && parts.size.between?(1, MAX_COUNCIL_PARTS)
  end

  def replay(saved)
    @context[:parts] = saved['parts'] || []
    @context[:part_plan] = saved['last_part_plan'].symbolize_keys
    @context[:part_plan_accepted] = true
    @context[:part_plan]
  end

  def normalize_part(raw, previous)
    item = raw.to_h.deep_stringify_keys
    graph_ids = Array(@context[:agent_graph]).pluck(:id)
    actor_id = Integer(item.fetch('executor_agent_id'))
    raise ArgumentError, 'That agent is not an agent of this turn' unless graph_ids.include?(actor_id)
    raise ArgumentError, 'Every part needs its fragment: the patient\'s own words.' if item['fragment'].to_s.strip.blank?

    prior = linked_prior(item, previous, actor_id)
    relation = RELATIONS.include?(item['relation'].to_s) ? item['relation'].to_s : (prior&.dig('relation') || 'independent')
    part_hash(item, prior, actor_id, relation, link_action_for(item['link_action'].to_s, prior))
  end

  # A linked item answers the open part unless it corrects or cancels it; an item without a link is a new part. A part that
  # already acted is not "cancelled" by a text: its owner runs again and undoes the action with its own tools.
  def link_action_for(named, prior)
    return 'new' unless prior
    return 'answer' unless CONTINUATION_ACTIONS.include?(named)

    named == 'cancellation' && prior['acted'] == true ? 'correction' : named
  end

  # The open part of the SAME agent the item continues; a link to another agent's part, a closed part or no part is a new part.
  def linked_prior(item, previous, actor_id)
    return if item['link_part_id'].blank?

    prior = previous.find { |part| part['id'] == item['link_part_id'] }
    prior if prior && OPEN_STATES.include?(prior['state']) && prior['executor_agent_id'].to_i == actor_id
  end

  def part_hash(item, prior, actor_id, relation, link_action)
    { 'id' => prior&.dig('id') || SecureRandom.uuid,
      'version' => prior ? prior['version'].to_i + 1 : 1,
      'executor_agent_id' => actor_id, 'fragment' => item['fragment'].to_s.strip.first(2000),
      'patient' => item['patient'].presence || 'unknown', 'relation' => relation,
      'object_refs' => item['object_refs'].presence || prior&.dig('object_refs') || [],
      'state' => link_action == 'cancellation' ? 'done' : 'open',
      'cancelled' => link_action == 'cancellation',
      'link_action' => link_action,
      'missing_fields' => [], 'summary' => nil, 'acted' => false,
      'prior_summary' => prior&.dig('summary'), 'prior_state' => prior&.dig('state'),
      'prior_questions' => Array(prior&.dig('missing_fields')),
      'prior_acted' => (prior && (prior['acted'] == true || prior['prior_acted'] == true)) || false,
      'delivered' => prior&.dig('delivered') || [] }.merge(kept_prerequisite(prior, relation))
  end

  def merge_into_context!(part_id, changes)
    part = Array(@context[:parts]).find { |item| item['id'] == part_id }
    raise ArgumentError, 'Part not found' unless part

    part.merge!(changes)
  end

  def changed_part(part_id, attributes)
    part = @context[:parts].find { |item| item['id'] == part_id }
    raise ArgumentError, 'Part not found' unless part

    changes = attributes.to_h.deep_stringify_keys.slice('state', 'missing_fields', 'delivered', 'executor_agent_id', 'summary', 'acted')
    raise ArgumentError, 'Invalid part state' if changes['state'] && !STATES.include?(changes['state'])
    if changes['executor_agent_id'] && Array(@context[:agent_graph]).pluck(:id).exclude?(changes['executor_agent_id'])
      raise ArgumentError, 'Agent is unavailable on this channel'
    end

    part.merge(changes)
  end

  def kept_prerequisite(prior, relation)
    pointer = prior&.dig('depends_on_part_id')
    PREREQUISITE_RELATIONS.include?(relation) && pointer.present? ? { 'depends_on_part_id' => pointer } : {}
  end

  # A new dependent part waits for the part planned directly before it in the same plan (a conditional part reads its result,
  # a depends_on part starts only when it succeeded). The code, not the model, fixes this link once.
  def link_prerequisites!(normalized)
    normalized.each_cons(2) do |previous, part|
      next unless part['version'] == 1 && PREREQUISITE_RELATIONS.include?(part['relation'])

      part['depends_on_part_id'] = previous['id']
    end
  end

  def persist_plan(plan, scope)
    return persist(plan[:parts]) unless @context[:agent_session]

    @context[:agent_session].change do |data|
      raise Captain::Conversation::ControlGenerationStaleError, 'Request plan changed' if data['last_part_plan_scope'] == scope

      data['parts'] ||= []
      merge_parts!(data['parts'], plan[:parts])
      data['last_part_plan_scope'] = scope
      data['last_part_plan'] = plan.deep_stringify_keys
      @context[:parts] = data['parts'].deep_dup
    end
  end

  def merge_parts!(stored, changed)
    changed.each do |part|
      index = stored.index { |item| item['id'] == part['id'] }
      index ? stored[index] = part.deep_dup : stored << part.deep_dup
    end
  end

  def persist(changed)
    if @context[:agent_session]
      @context[:agent_session].change do |data|
        data['parts'] ||= []
        merge_parts!(data['parts'], changed)
        @context[:parts] = data['parts'].deep_dup
      end
    else
      @context[:parts] ||= []
      merge_parts!(@context[:parts], changed)
    end
  end
end
