# frozen_string_literal: true

# The model names the agent that owns a request part by the name shown in the coordination prompt and never sees agent ids.
# The part registry stores ids, so the name is resolved here, in one place, before a plan is accepted. A plan that contradicts
# itself (a council of one agent, a plan in the former handoff mode) is rejected here with a
# retryable error that tells the model what to change, so a correctable plan never ends the turn in the generic error.
class Captain::Runtime::ExecutorResolver
  # The model can correct the call and plan again.
  class RetryableError < ArgumentError
    def reason = 'plan_conflict'
  end

  class UnknownAgentError < RetryableError
    def reason = 'unknown_executor'
  end

  # Passing the conversation to one colleague is the colleague's transfer tool, never a plan.
  class TransferToolError < RetryableError
    def reason = 'use_transfer_tool'
  end

  STRICT_MODES = %w[council].freeze
  COUNCIL_HINT = Captain::Runtime::PartRegistry::COUNCIL_HINT
  EDGE_NOISE = /\A[[:space:]"'`«»“”„‘’‹›]+|[[:space:]"'`«»“”„‘’‹›]+\z/
  PERSON_HINT = 'To reach a person call the handoff tool.'
  OWN_WORK_NOTE = Captain::Runtime::PartRegistry::OWN_WORK_NOTE

  def self.normalize(value)
    text = value.to_s
    text = text.unicode_normalize(:nfkc) if text.encoding.name.start_with?('UTF')
    text.gsub(EDGE_NOISE, '').squish.downcase
  rescue ArgumentError, Encoding::CompatibilityError
    value.to_s.squish.downcase
  end

  def initialize(context)
    @agents = Array(context[:agent_graph])
    @parts = Array(context[:parts])
    @current_id = context.dig(:state, :assistant_id)
  end

  # Returns copies of the parts that carry the registry's integer executor_agent_id instead of the model's executor.
  def resolve(parts, mode:)
    return parts unless parts.is_a?(Array)

    items = parts.map { |raw| raw.to_h.deep_stringify_keys }
    resolved = items.map { |item| with_executor_id(item, mode) }
    check_council!(resolved) if mode == 'council'
    resolved
  end

  def name_for(agent_id)
    @agents.find { |agent| agent[:id] == agent_id }&.dig(:name).to_s.squish.presence
  end

  # A request that belongs to one colleague is not planned: the model passes the conversation with that colleague's transfer
  # tool. A model that still asks for the former mode 'handoff' is told so, with the names it can choose from. The customer's
  # answer to an open part of another agent is not a transfer either: it is a council of that one part.
  def reject_transfer_mode!(mode, parts = nil)
    return unless mode.to_s == 'handoff'
    raise TransferToolError, "plan_request has no handoff mode. #{COUNCIL_HINT}" if continuation_of_peer?(parts)

    names = selectable_names(exclude_current: true)
    raise TransferToolError, no_peer_message('handoff') if names.empty?

    raise TransferToolError, 'plan_request has no handoff mode. To pass the conversation to one colleague, call that colleague\'s ' \
                             "transfer tool without a plan. Colleagues: #{names.join(', ')}. #{PERSON_HINT} " \
                             'plan_request is only for a council (separate requests for different agents) and for the answer to an open part.'
  end

  private

  # A part that is linked to an open part keeps the agent that owns it: an answer, a correction or a cancellation is not moved to
  # the current agent, and the executor the model named is ignored. Every other part is the named agent's.
  def with_executor_id(item, mode)
    rest = item.except('executor', 'executor_agent_id')
    return rest.merge('executor_agent_id' => fallback_id_for(rest)) if continuation?(item)

    rest.merge('executor_agent_id' => agent_id_for(reference_for(item), mode, fallback_id_for(rest)))
  end

  # The agent name; only a model that still answers in the former schema sends the numeric executor_agent_id.
  def reference_for(item)
    return item['executor'] if item['executor'].present?

    legacy = item['executor_agent_id']
    legacy.to_s.match?(/\A\d+\z/) ? "assistant_#{legacy}" : legacy
  end

  # An omitted executor, and an unknown one in a mode where the part is the current agent's own by definition, mean the fallback.
  def agent_id_for(reference, mode, fallback_id)
    key = self.class.normalize(reference)
    return fallback_id if key.empty?

    named = @agents.select { |agent| key_of(agent) == key }
    return named.first[:id] if named.one?

    keyed = agent_by_key(key) if named.empty?
    return keyed[:id] if keyed
    return fallback_id unless STRICT_MODES.include?(mode)

    raise UnknownAgentError, unknown_message(reference, named.many?)
  end

  # A plain number is never taken for an agent: the model does not see ids, so a number can only be a guess. The key of an agent
  # (assistant_4, or agent_4 as in its transfer tool name) is read.
  def agent_by_key(key)
    id = Captain::HandoffNaming.agent_id_from_key(key)
    @agents.find { |agent| agent[:id] == id } if id
  end

  # The current agent. A part linked to an open part keeps the executor recorded on it: an answer, a correction or a
  # cancellation of a peer's part does not silently move that part to the current agent.
  def fallback_id_for(item)
    return @current_id if item['link_part_id'].blank? || item['link_action'].to_s == 'new'

    stored = stored_part(item['link_part_id'])&.dig('executor_agent_id')
    @agents.any? { |agent| agent[:id] == stored } ? stored : @current_id
  end

  def stored_part(part_id)
    @parts.find { |part| part['id'] == part_id }
  end

  # The customer's answer, correction or cancellation of an open part (not a new request).
  def continuation?(item)
    item['link_part_id'].present? && item['link_action'].to_s != 'new' && stored_part(item['link_part_id']).present?
  end

  def continuation_of_peer?(parts)
    Array(parts).any? do |raw|
      item = raw.to_h.deep_stringify_keys
      continuation?(item) && fallback_id_for(item) != @current_id
    end
  end

  # A council is separate requests for at least two agents, or the continuation of open parts (one part is enough: the
  # customer answers a question of the agent that asked it).
  def check_council!(resolved)
    return if resolved.pluck('executor_agent_id').uniq.size >= 2 || resolved.all? { |item| continuation?(item) }

    names = selectable_names(exclude_current: true)
    raise RetryableError, no_peer_message('council') if names.empty?

    raise RetryableError, 'Council needs parts for at least two different agents, from the patient\'s latest message only: name the ' \
                          "executor of each part, one of: #{names.join(', ')}. A latest message with one request needs no plan: " \
                          'answer it with your tools or transfer it to its colleague.'
  end

  def unknown_message(reference, ambiguous)
    shown = reference.to_s.squish.first(80)
    lead = ambiguous ? %(Unknown agent "#{shown}" (several agents share this name).) : %(Unknown agent "#{shown}".)
    names = selectable_names(exclude_current: false)
    return "#{lead} #{no_peer_message('council')}" if names.empty?

    "#{lead} Use one of: #{names.join(', ')}"
  end

  def no_peer_message(mode)
    return "No other agent can be chosen on this channel. #{PERSON_HINT} #{OWN_WORK_NOTE}" if mode == 'handoff'

    "No other agent can be chosen on this channel. #{OWN_WORK_NOTE}"
  end

  # Only names that point to exactly one agent can be used; excluding the current agent lists the colleagues.
  def selectable_names(exclude_current:)
    counts = @agents.map { |agent| key_of(agent) }.tally
    candidates = @agents.select { |agent| key_of(agent).present? && counts[key_of(agent)] == 1 }
    candidates = candidates.reject { |agent| agent[:id] == @current_id } if exclude_current
    candidates.map { |agent| agent[:name].to_s.squish }
  end

  def key_of(agent)
    self.class.normalize(agent[:name])
  end
end
