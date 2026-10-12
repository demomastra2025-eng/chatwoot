# frozen_string_literal: true

# The durable plan belongs to a conversation, not to its current agent.
class Captain::Runtime::PartRegistry
  MAX_COUNCIL_PARTS = 3
  MAX_PARTS_PER_MESSAGE = 30
  SUMMARY_LIMIT = 600
  # The sentence told to the customer for a part stays whole up to the length of one message.
  REPLY_TEXT_LIMIT = 3000
  STATES = %w[open answered waiting_customer done failed unknown].freeze
  OPEN_STATES = %w[open waiting_customer unknown].freeze
  # The modes a new plan can have. Passing the conversation to one colleague is that colleague's transfer tool, not a plan.
  # A plan stored with the former mode 'handoff' is still replayed as it was saved (see Runner#handle_plan), never re-validated.
  MODES = %w[answer_myself council clarify].freeze
  RELATIONS = %w[independent conditional depends_on].freeze
  PREREQUISITE_RELATIONS = %w[depends_on conditional].freeze
  LINK_ACTIONS = %w[new answer correction cancellation].freeze
  # A model that still sends the former link action is understood: a customer's "да" is an answer to the part's question.
  LEGACY_LINK_ACTIONS = { 'confirmation' => 'answer' }.freeze
  ALREADY_PLANNED = 'This message already has a plan'
  COUNCIL_HINT = 'The customer answers, corrects or cancels a part of another agent: call plan_request with mode council and ' \
                 'ONLY that part linked by its number. Its own agent continues it with its own tools.'

  # The plan coordinates agents (a council, the answer to an open part), so it exists only where another agent is
  # available. A lone agent has no plan_request and acts with its own tools.
  def self.planning_available?(context)
    actor_id = context.dig(:state, :assistant_id)
    Array(context[:agent_graph]).any? { |actor| actor[:id] != actor_id }
  end

  # A part of another agent waits for the customer's answer, and its question is the last thing the customer was told: the
  # message that follows is probably the answer, and only a plan routes it to the agent that asked.
  def self.awaiting_peer_answer?(context)
    actor_id = context.dig(:state, :assistant_id)
    last = last_reply_text(context[:conversation_history])
    return false if last.blank?

    Array(context[:parts]).any? do |part|
      part['state'] == 'waiting_customer' && part['executor_agent_id'] != actor_id &&
        deliveries_of_version(part).any? { |delivery| delivery['content'].to_s.strip == last }
    end
  end

  # What was sent to the customer for THIS version of the part. A new version starts from the deliveries of the one before it, so
  # each delivery records the version it reported (see ResponseBuilderJob#record_part_delivery); one written before versions were
  # recorded counts for every version.
  def self.deliveries_of_version(part)
    Array(part['delivered']).select { |delivery| delivery['version'].nil? || delivery['version'].to_i == part['version'].to_i }
  end

  def self.last_reply_text(history)
    message = Array(history).reverse.map { |raw| raw.to_h.with_indifferent_access }.find { |item| item[:role].to_s == 'assistant' }
    return if message.blank?

    content = message[:content]
    parsed = content.is_a?(String) ? JSON.parse(content) : content
    (parsed.is_a?(Hash) && parsed.key?('response') ? parsed['response'] : content).to_s.strip.presence
  rescue JSON::ParserError
    content.to_s.strip.presence
  end

  # Actions a specialist performed in an earlier run whose reply never reached the customer (the reply was dropped because a
  # newer message arrived): the next reply must tell the customer. The action of a follow-up version (the customer answered, the
  # version booked) is reported by a delivery of that version, not by the question that an earlier version delivered.
  def self.undelivered_outcomes(parts)
    Array(parts).select { |part| part['acted'] == true && part['cancelled'] != true && deliveries_of_version(part).empty? }
  end

  # The number a part is listed with in the prompt (#3) and linked by: its position among the stored parts of the conversation.
  # The list only grows (a part is replaced in place), so a number does not change while the part is open.
  def self.number_of(parts, part_id)
    index = Array(parts).index { |item| item['id'] == part_id }
    index + 1 if index
  end

  # The exact id of the stored part that the model means: it writes the number ("3" or "#3"), or still the exact id. A number
  # that points at no stored part is returned as written, and the plan is refused as linking a part that is not open.
  def self.part_id_for(parts, reference)
    text = reference.to_s.strip
    number = text.delete_prefix('#')[/\A\d+\z/]
    return text if number.nil? || number.to_i < 1

    Array(parts)[number.to_i - 1]&.dig('id') || text
  end

  def initialize(context)
    @context = context
  end

  # The optional block turns the model's parts into registry parts (see ExecutorResolver) once the plan is known to be new:
  # a plan that was already accepted for this request is replayed as it was saved.
  def accept!(mode:, parts:, clarification: nil, answer: nil)
    scope = Captain::Runtime::TaskQueue.new(@context).request_scope
    saved = @context[:agent_session]&.read
    return replay(saved) if saved && saved['last_part_plan_scope'] == scope

    raise ArgumentError, 'Invalid request mode' unless MODES.include?(mode)
    max_parts = mode == 'council' ? MAX_COUNCIL_PARTS : MAX_PARTS_PER_MESSAGE
    raise ArgumentError, 'Council needs one to three parts' if mode == 'council' && (!parts.is_a?(Array) || !parts.size.between?(1, max_parts))
    raise ArgumentError, 'A request needs one to thirty parts' unless parts.is_a?(Array) && parts.size.between?(1, max_parts)
    raise ArgumentError, ALREADY_PLANNED if @context[:part_plan_accepted]

    parts = yield(parts) if block_given?
    previous = Array(@context[:parts])
    linked_ids = parts.filter_map { |item| item.to_h.stringify_keys['link_part_id'].presence }
    raise ArgumentError, 'A part can only be linked once per message' if linked_ids.uniq.size != linked_ids.size

    normalized = parts.map { |raw| normalize_part(raw, previous, mode) }
    link_prerequisites!(normalized)
    validate_plan!(mode, normalized, clarification, answer)

    plan = { mode: mode, parts: normalized, clarification: clarification.to_s.strip, answer: answer.to_s.strip }
    persist_plan(plan, scope)
    @context[:part_plan] = plan
    @context[:part_plan_accepted] = true
    activate_single_part(normalized, mode)
    @context[:part_plan]
  end

  def update!(part_id, attributes)
    persist([changed_part(part_id, attributes)])
  end

  # The result of a part, written by the council. It goes straight to the stored part and merges ONLY the keys it is given, so
  # that nothing written meanwhile (for example deliveries) is lost. It does not require the run to be current: the action of a
  # part (a booking) has already happened, and it must be on record even when the reply is later dropped. A council part runs
  # with a context that has neither the parts nor the graph, so nothing here may depend on them.
  #
  # summary is what the tools of the part returned, for the model and for staff. reply_text is the sentence the customer is told
  # for the part: a retried request replays it. technical is the failure that stopped the part (names and codes only), so that the
  # replay hands the conversation to staff as the first attempt did.
  def record_result!(part_id, state: nil, summary: nil, missing_fields: nil, executor_agent_id: nil, acted: nil, reply_text: nil, technical: nil)
    raise ArgumentError, 'Invalid part state' if state && !STATES.include?(state)

    changes = { 'state' => state, 'executor_agent_id' => executor_agent_id, 'acted' => acted }.compact
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

  def replay(saved)
    @context[:parts] = saved['parts'] || []
    @context[:part_plan] = saved['last_part_plan'].symbolize_keys
    @context[:part_plan_accepted] = true
    activate_single_part(@context[:part_plan][:parts], @context[:part_plan][:mode])
    @context[:part_plan]
  end

  def normalize_part(raw, previous, mode)
    item = raw.to_h.deep_stringify_keys
    graph_ids = Array(@context[:agent_graph]).pluck(:id)
    actor_id = Integer(item.fetch('executor_agent_id'))
    raise ArgumentError, 'Agent is unavailable on this channel' unless graph_ids.include?(actor_id)
    raise ArgumentError, 'Missing message fragment' if item['fragment'].to_s.strip.blank?

    prior = previous.find { |part| part['id'] == item['link_part_id'] }
    raise ArgumentError, 'Linked part is not open' if item['link_part_id'].present? && (!prior || !OPEN_STATES.include?(prior['state']))

    relation = item['relation'].presence || prior&.dig('relation') || 'independent'
    raise ArgumentError, 'Invalid part relation' unless RELATIONS.include?(relation)

    link_action = LEGACY_LINK_ACTIONS.fetch(item['link_action'].to_s, item['link_action'].presence) || 'answer'
    raise ArgumentError, 'Invalid link action' unless LINK_ACTIONS.include?(link_action)

    open_parts = previous.select { |part| OPEN_STATES.include?(part['state']) }
    if prior.nil? && open_parts.any? && mode != 'clarify' && link_action != 'new'
      raise ArgumentError, 'Identify this as a new request or link an open part'
    end

    # A part that already acted is not "cancelled" by a text: its owner runs again and undoes the action with its own tools.
    link_action = 'correction' if link_action == 'cancellation' && prior&.dig('acted') == true
    actor_id = pinned_executor(prior, link_action, actor_id, graph_ids)
    part_hash(item, prior, actor_id, relation, link_action)
  end

  # A continuation keeps the agent that owns the part, whatever executor the model named.
  def pinned_executor(prior, link_action, actor_id, graph_ids)
    return actor_id if prior.nil? || link_action == 'new'

    graph_ids.include?(prior['executor_agent_id']) ? prior['executor_agent_id'] : actor_id
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
      'prior_summary' => prior&.dig('summary'), 'prior_questions' => Array(prior&.dig('missing_fields')),
      'prior_acted' => (prior && (prior['acted'] == true || prior['prior_acted'] == true)) || false,
      'delivered' => prior&.dig('delivered') || [] }.merge(kept_prerequisite(prior, relation))
  end

  def validate_plan!(mode, normalized, clarification, answer)
    continuations = normalized.all? { |part| part['version'] > 1 }
    # A council is separate requests for different agents, or the answer to an open part of another agent (one part is enough).
    if mode == 'council' && !continuations && normalized.pluck('executor_agent_id').uniq.size < 2
      raise ArgumentError, 'Council needs at least two agents'
    end
    raise ArgumentError, 'Clarification must be precise' if mode == 'clarify' && clarification.to_s.strip.blank?
    raise ArgumentError, 'An immediate answer needs one own part' if answer.present? && (mode != 'answer_myself' || normalized.size != 1)

    current_id = @context.dig(:state, :assistant_id)
    return unless mode == 'answer_myself' && normalized.any? { |part| part['executor_agent_id'] != current_id }

    raise ArgumentError, "This part belongs to another agent. #{COUNCIL_HINT}"
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

  # Only a plan for the current agent's own single part runs under that part's scope. The parts of a council run under their
  # own contexts, and the acting agent takes no part scope of its own then.
  def activate_single_part(parts, mode)
    return unless parts.one? && mode.to_s != 'council'

    part = parts.first
    @context[:active_part_id] = part['id']
    @context[:active_part_version] = part['version']
    fence = @context.dig(:state, :captain_response_fence)
    return unless fence

    fence[:part_id] = part['id']
    fence[:part_version] = part['version']
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
