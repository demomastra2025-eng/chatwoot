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
  # The modes a new plan can have. Passing the conversation to one colleague is that colleague's transfer tool, and an agent's own
  # work needs no plan at all. A plan stored with the former mode 'handoff' or 'answer_myself' is still replayed as it was saved
  # (see Runner#handle_plan), never re-validated.
  MODES = %w[council clarify].freeze
  OWN_WORK_NOTE = 'Own work needs no plan: answer or use your tools.'
  MODE_HELP = 'Valid modes: council (actions for different agents, or one open part of another agent that the message answers, ' \
              'corrects or cancels) and clarify (one question, when two or more open parts could be meant).'
  INVALID_MODE = "Invalid mode. #{MODE_HELP} #{OWN_WORK_NOTE}".freeze
  ONE_OPEN_PART = 'One part is open: link the message to it by its number.'
  NO_OPEN_PART = 'No part is open: reply to the patient yourself.'
  # What a message is that does not continue an open part: one colleague takes it by transfer, several agents get a plan.
  NEW_ACTION_NOTE = 'For a new action: when it belongs to one colleague, transfer the conversation with that colleague\'s transfer ' \
                    'tool; for actions of two or more agents call plan_request without link_part_id and with link_action new.'
  CLOSED_PART_NOTE = 'If the message only repeats or confirms what the part did, reply to the patient yourself.'
  STAFF_PART_NOTE = 'If the message adds details for staff, pass them with the handoff tool.'
  RELATIONS = %w[independent conditional depends_on].freeze
  PREREQUISITE_RELATIONS = %w[depends_on conditional].freeze
  LINK_ACTIONS = %w[new answer correction cancellation].freeze
  # A model that still sends the former link action is understood: a customer's "да" is an answer to the part's question.
  LEGACY_LINK_ACTIONS = { 'confirmation' => 'answer' }.freeze
  ALREADY_PLANNED = 'This message already has a plan: each agent of the plan does its part, so continue with your own work.'
  COUNCIL_HINT = 'The patient answers, corrects or cancels a part of another agent: call plan_request with mode council and ' \
                 'ONLY that part linked by its number (link_part_id). Its own agent continues it with its own tools.'

  # The plan coordinates agents (a council, the answer to an open part), so it exists only where another agent is
  # available. A lone agent has no plan_request and acts with its own tools.
  def self.planning_available?(context)
    actor_id = context.dig(:state, :assistant_id)
    Array(context[:agent_graph]).any? { |actor| actor[:id] != actor_id }
  end

  # The open parts the model is shown and can link a message to: parts of the OTHER agents that are still open. The agent's own
  # parts need no plan (it answers them with its tools), and a part already handed to staff is theirs now. Linking such a part by
  # its number stays possible; it is only not listed.
  def self.listed_parts(context)
    actor_id = context.dig(:state, :assistant_id)
    Array(context[:parts]).select do |part|
      OPEN_STATES.include?(part['state']) && part['executor_agent_id'] != actor_id && part['handed_to_staff'] != true
    end
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

  # The numbers (#3) of the parts the model can link, as the prompt lists them (open parts of the other agents).
  def self.open_numbers(context)
    stored = Array(context[:parts])
    listed_parts(context).map { |part| "##{number_of(stored, part['id'])}" }
  end

  # What is wrong with a link, written for the model: the number points at no part.
  def self.unknown_link_message(context, reference)
    open = open_numbers(context)
    state = open.any? ? "Open parts: #{open.join(', ')}. If the message answers one of them, link its number." : 'No part is open.'
    "There is no part #{reference.to_s.squish.first(20)}. #{state} #{NEW_ACTION_NOTE}"
  end

  # What is wrong with a link, written for the model: the part is finished or with staff, so the message continues nothing. What it
  # repeats is answered by the agent itself; what is new goes by transfer or by a new plan.
  def self.closed_link_message(context, prior)
    number = number_of(Array(context[:parts]), prior['id'])
    where = if prior['handed_to_staff'] == true
              "is with staff, who will answer it. #{STAFF_PART_NOTE}"
            else
              "is closed (#{prior['state']}). #{CLOSED_PART_NOTE}"
            end
    "Part ##{number} #{where} #{NEW_ACTION_NOTE}"
  end

  # The mode is not one of MODES. A link to an open part tells the model which mode it meant.
  def self.invalid_mode_message(parts)
    linked = Array(parts).any? { |part| part.respond_to?(:to_h) && part.to_h.stringify_keys['link_part_id'].present? }
    linked ? "#{INVALID_MODE} #{COUNCIL_HINT}" : INVALID_MODE
  end

  def initialize(context)
    @context = context
  end

  # The optional block turns the model's parts into registry parts (see ExecutorResolver) once the plan is known to be new:
  # a plan that was already accepted for this request is replayed as it was saved.
  def accept!(mode:, parts:, clarification: nil)
    scope = Captain::Runtime::TaskQueue.new(@context).request_scope
    saved = @context[:agent_session]&.read
    return replay(saved) if saved && saved['last_part_plan_scope'] == scope

    raise ArgumentError, self.class.invalid_mode_message(parts) unless MODES.include?(mode)

    max_parts = mode == 'council' ? MAX_COUNCIL_PARTS : MAX_PARTS_PER_MESSAGE
    if mode == 'council' && (!parts.is_a?(Array) || !parts.size.between?(1, max_parts))
      raise ArgumentError, 'A council has one to three parts: put the actions that one agent does into one part.'
    end
    raise ArgumentError, 'parts needs one to thirty items: one item per action.' unless parts.is_a?(Array) && parts.size.between?(1, max_parts)
    raise ArgumentError, ALREADY_PLANNED if @context[:part_plan_accepted]

    parts = yield(parts) if block_given?
    previous = Array(@context[:parts])
    linked_ids = parts.filter_map { |item| item.to_h.stringify_keys['link_part_id'].presence }
    if linked_ids.uniq.size != linked_ids.size
      raise ArgumentError, 'An open part is linked by one item only: put the answers to one part into one item.'
    end

    normalized = parts.map { |raw| normalize_part(raw, previous, mode) }
    link_prerequisites!(normalized)
    validate_plan!(mode, normalized, clarification)

    plan = { mode: mode, parts: normalized, clarification: clarification.to_s.strip }
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
    raise ArgumentError, 'That agent is not on this channel: name an agent listed under Colleagues.' unless graph_ids.include?(actor_id)
    raise ArgumentError, 'Every part needs its fragment: the patient\'s own words that make this action.' if item['fragment'].to_s.strip.blank?

    prior = previous.find { |part| part['id'] == item['link_part_id'] }
    if item['link_part_id'].present? && (!prior || !OPEN_STATES.include?(prior['state']))
      raise ArgumentError, prior ? self.class.closed_link_message(@context, prior) : self.class.unknown_link_message(@context, item['link_part_id'])
    end

    relation = item['relation'].presence || prior&.dig('relation') || 'independent'
    raise ArgumentError, "Invalid relation. Valid relations: #{RELATIONS.join(', ')}." unless RELATIONS.include?(relation)

    named = LEGACY_LINK_ACTIONS.fetch(item['link_action'].to_s, item['link_action'].presence)
    raise ArgumentError, "Invalid link_action. Valid link actions: #{LINK_ACTIONS.join(', ')}." unless named.nil? || LINK_ACTIONS.include?(named)

    # Only the parts the model is shown force the decision: it cannot link or declare "new" against a part it is not told about.
    raise ArgumentError, link_required_message if prior.nil? && self.class.listed_parts(@context).any? && mode != 'clarify' && named != 'new'

    # An item that links a part answers it unless it says more; an item without a link is a new action. The owner reads this word.
    link_action = named || (prior ? 'answer' : 'new')

    # A part that already acted is not "cancelled" by a text: its owner runs again and undoes the action with its own tools.
    link_action = 'correction' if link_action == 'cancellation' && prior&.dig('acted') == true
    actor_id = pinned_executor(prior, link_action, actor_id, graph_ids)
    part_hash(item, prior, actor_id, relation, link_action)
  end

  # Open parts of colleagues exist, so every item says which one it answers or that it is new: the numbers are listed here.
  def link_required_message
    numbers = self.class.open_numbers(@context)
    "Open parts of colleagues: #{numbers.join(', ')}. If this item answers, corrects or cancels one of them, give link_part_id " \
      'with its number and link_action answer, correction or cancellation. A separate new action has link_action new.'
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
      'prior_summary' => prior&.dig('summary'), 'prior_state' => prior&.dig('state'),
      'prior_questions' => Array(prior&.dig('missing_fields')),
      'prior_acted' => (prior && (prior['acted'] == true || prior['prior_acted'] == true)) || false,
      'delivered' => prior&.dig('delivered') || [] }.merge(kept_prerequisite(prior, relation))
  end

  def validate_plan!(mode, normalized, clarification)
    continuations = normalized.all? { |part| part['version'] > 1 }
    # A council is separate actions for different agents, or the answer to an open part of another agent (one part is enough).
    if mode == 'council' && !continuations && normalized.pluck('executor_agent_id').uniq.size < 2
      raise ArgumentError, 'A council needs actions for at least two different agents. When all actions belong to one colleague, ' \
                           'transfer the conversation with that colleague\'s transfer tool.'
    end
    return unless mode == 'clarify'

    raise ArgumentError, 'Clarification must be precise: give the one question for the patient in clarification.' if clarification.to_s.strip.blank?

    # The question is for a patient whose message could mean one of two or more listed parts; with fewer there is nothing to ask.
    listed = self.class.listed_parts(@context).size
    raise ArgumentError, NO_OPEN_PART if listed.zero?
    raise ArgumentError, ONE_OPEN_PART if listed == 1
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
