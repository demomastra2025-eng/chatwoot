# frozen_string_literal: true

# The durable plan belongs to a conversation, not to its current agent.
class Captain::Runtime::PartRegistry
  MAX_COUNCIL_PARTS = 3
  MAX_PARTS_PER_MESSAGE = 30
  STATES = %w[open answered waiting_customer waiting_confirmation done failed unknown].freeze
  OPEN_STATES = %w[open waiting_customer waiting_confirmation unknown].freeze
  MODES = %w[answer_myself handoff council clarify].freeze
  RELATIONS = %w[independent conditional depends_on].freeze
  LINK_ACTIONS = %w[new answer correction cancellation confirmation].freeze

  def initialize(context)
    @context = context
  end

  def accept!(mode:, parts:, clarification: nil, answer: nil)
    scope = Captain::Runtime::TaskQueue.new(@context).request_scope
    saved = @context[:agent_session]&.read
    if saved && saved['last_part_plan_scope'] == scope
      @context[:parts] = saved['parts'] || []
      @context[:part_plan] = saved['last_part_plan'].symbolize_keys
      @context[:part_plan_accepted] = true
      activate_single_part(@context[:part_plan][:parts])
      return @context[:part_plan]
    end

    raise ArgumentError, 'Invalid request mode' unless MODES.include?(mode)
    max_parts = mode == 'council' ? MAX_COUNCIL_PARTS : MAX_PARTS_PER_MESSAGE
    raise ArgumentError, 'Council needs one to three parts' if mode == 'council' && (!parts.is_a?(Array) || !parts.size.between?(1, max_parts))
    raise ArgumentError, 'A request needs one to thirty parts' unless parts.is_a?(Array) && parts.size.between?(1, max_parts)
    raise ArgumentError, 'This message already has a plan' if @context[:part_plan_accepted]

    graph_ids = Array(@context[:agent_graph]).pluck(:id)
    previous = Array(@context[:parts])
    open_parts = previous.select { |part| OPEN_STATES.include?(part['state']) }
    linked_ids = parts.filter_map { |item| item.to_h.stringify_keys['link_part_id'].presence }
    raise ArgumentError, 'A part can only be linked once per message' if linked_ids.uniq.size != linked_ids.size

    normalized = parts.map do |raw|
      item = raw.to_h.deep_stringify_keys
      actor_id = Integer(item.fetch('executor_agent_id'))
      raise ArgumentError, 'Agent is unavailable on this channel' unless graph_ids.include?(actor_id)
      raise ArgumentError, 'Missing message fragment' if item['fragment'].to_s.strip.blank?
      prior = previous.find { |part| part['id'] == item['link_part_id'] }
      raise ArgumentError, 'Linked part is not open' if item['link_part_id'].present? && (!prior || !OPEN_STATES.include?(prior['state']))
      relation = item['relation'].presence || prior&.dig('relation') || 'independent'
      raise ArgumentError, 'Invalid part relation' unless RELATIONS.include?(relation)
      link_action = item['link_action'].presence || 'answer'
      raise ArgumentError, 'Invalid link action' unless LINK_ACTIONS.include?(link_action)
      if prior.nil? && open_parts.any? && mode != 'clarify' && link_action != 'new'
        raise ArgumentError, 'Identify this as a new request or link an open part'
      end
      if link_action == 'confirmation' && (!prior || prior['state'] != 'waiting_confirmation' || prior['proposed_operation'].blank?)
        raise ArgumentError, 'There is no operation awaiting confirmation for this part'
      end

      { 'id' => prior&.dig('id') || SecureRandom.uuid,
        'version' => prior ? prior['version'].to_i + 1 : 1,
        'executor_agent_id' => actor_id, 'fragment' => item['fragment'].to_s.strip.first(2000),
        'patient' => item['patient'].presence || 'unknown', 'relation' => relation,
        'object_refs' => item['object_refs'].presence || prior&.dig('object_refs') || [],
        'state' => link_action == 'cancellation' ? 'done' : 'open',
        'cancelled' => link_action == 'cancellation',
        'link_action' => link_action,
        'missing_fields' => [], 'proposed_operation' => link_action == 'confirmation' ? prior['proposed_operation'] : nil,
        'delivered' => prior&.dig('delivered') || [] }
    end
    raise ArgumentError, 'Council needs at least two agents' if mode == 'council' && normalized.pluck('executor_agent_id').uniq.size < 2
    raise ArgumentError, 'Clarification must be precise' if mode == 'clarify' && clarification.to_s.strip.blank?
    raise ArgumentError, 'An immediate answer needs one own part' if answer.present? &&
                                                                   (mode != 'answer_myself' || normalized.size != 1)
    current_id = @context.dig(:state, :assistant_id)
    wrong_agent = normalized.any? { |part| part['executor_agent_id'] != current_id }
    raise ArgumentError, 'This part belongs to another agent' if mode == 'answer_myself' && wrong_agent
    handoff_ids = normalized.pluck('executor_agent_id').uniq
    raise ArgumentError, 'Handoff needs one different agent' if mode == 'handoff' &&
                                                           (handoff_ids.size != 1 || handoff_ids.first == current_id)

    plan = { mode: mode, parts: normalized, clarification: clarification.to_s.strip, answer: answer.to_s.strip }
    persist_plan(plan, scope)
    @context[:part_plan] = plan
    @context[:part_plan_accepted] = true
    activate_single_part(normalized)
    @context[:part_plan]
  end

  def update!(part_id, attributes)
    part = @context[:parts].find { |item| item['id'] == part_id }
    raise ArgumentError, 'Part not found' unless part

    changes = attributes.to_h.deep_stringify_keys.slice('state', 'missing_fields', 'proposed_operation', 'delivered',
                                                       'executor_agent_id')
    raise ArgumentError, 'Invalid part state' if changes['state'] && !STATES.include?(changes['state'])
    if changes['executor_agent_id'] && Array(@context[:agent_graph]).pluck(:id).exclude?(changes['executor_agent_id'])
      raise ArgumentError, 'Agent is unavailable on this channel'
    end

    persist([part.merge(changes)])
  end

  private

  def activate_single_part(parts)
    return unless parts.one?

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
