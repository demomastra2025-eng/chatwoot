# frozen_string_literal: true

# What the coordination events of one turn say: which agent handed the conversation to which colleague, what the parts of a
# council did and how they ended, how the editor wrote the reply, and which tool failed technically. The events carry
# identifiers, states and counts only (Captain::Runtime::CoordinationEvents); this class turns the ids into agent names and
# keeps the part end states, so a failure of a council turn can be diagnosed from the report ("the slot-offer part ended as
# `answered`, so the follow-up became a transfer").
#
# `events` is every LlmEvent of the turn window (not only those of one request id): the parts of a council may run under
# another request id.
class Captain::Evals::RoutingBenchmark::TurnEvents
  TRANSFER = 'captain.agent.transfer'
  TRANSFER_GUARD = 'captain.agent.transfer_guard'
  COUNCIL_STARTED = 'captain.council.started'
  PART_STARTED = 'captain.council.part_started'
  PART_FINISHED = 'captain.council.part_finished'
  COUNCIL_FINISHED = 'captain.council.finished'
  COUNCIL_EDITED = 'captain.council.edited'
  EDITOR_FALLBACK = 'captain.council.editor_fallback'
  TECHNICAL_FAILURE = 'captain.tool.technical_failure'
  PART_COUNTS = %w[mutations_succeeded mutations_failed mutations_unknown tools_called turns].freeze

  attr_reader :events

  # agent_names: { assistant id => name }
  def initialize(events, agent_names: {})
    @events = events.to_a
    @names = agent_names
  end

  def transfers
    named(TRANSFER).map { |event| { from: agent(field(event, 'from_agent_id')), to: agent(field(event, 'to_agent_id')) } }
  end

  def transfer_guards
    named(TRANSFER_GUARD).map do |event|
      { reason: field(event, 'reason'), from: agent(field(event, 'from_agent_id')), to: agent(field(event, 'to_agent_id')) }.compact
    end
  end

  def council_started? = named(COUNCIL_STARTED).any?

  def part_started? = named(PART_STARTED).any?

  # nil when the turn had no council event at all.
  def council
    return if (named(COUNCIL_STARTED) + named(PART_STARTED) + named(COUNCIL_FINISHED) + named(COUNCIL_EDITED) + named(EDITOR_FALLBACK)).empty?

    {
      started: named(COUNCIL_STARTED).size,
      participants: named(COUNCIL_STARTED).flat_map { |event| Array(field(event, 'participants')).map { |id| agent(id) } }.uniq,
      parts: parts, outcome: named(COUNCIL_FINISHED).filter_map { |event| field(event, 'outcome') }.last,
      edited: edited, editor_fallback: named(EDITOR_FALLBACK).filter_map { |event| field(event, 'reason') }.last
    }.compact
  end

  def editor_fallback = named(EDITOR_FALLBACK).filter_map { |event| field(event, 'reason') }.last

  # [{ tool:, stage:, reason:, mutating: }] of the tools whose technical failure stopped a run.
  def technical_failures
    named(TECHNICAL_FAILURE).map do |event|
      { tool: event.tool_name, stage: field(event, 'stage'), reason: field(event, 'reason'), mutating: field(event, 'mutating') }.compact
    end
  end

  private

  def named(name) = events.select { |event| event.event_name == name }

  def field(event, key) = Captain::Evals::RoutingBenchmark::ToolTrace.field(event, key)

  def agent(id)
    return if id.blank?

    @names.fetch(id.to_i, "assistant_#{id}")
  end

  # One entry per part: the start (owner, lane) merged with the end (state, status, acted, counts).
  def parts
    started = named(PART_STARTED).group_by { |event| part_key(event) }
    finished = named(PART_FINISHED).group_by { |event| part_key(event) }
    (started.keys | finished.keys).map do |key|
      start = started[key]&.first
      finish = finished[key]&.last
      part_entry(start || finish, start, finish)
    end
  end

  def part_key(event) = [field(event, 'part_id'), field(event, 'part_version')]

  def part_entry(base, start, finish)
    entry = { part: field(base, 'part_id').to_s.first(8), version: field(base, 'part_version'),
              owner: agent(field(base, 'executor_agent_id')) }
    entry[:lane] = field(start, 'lane') if start
    entry[:inline] = field(start, 'inline') if start && !field(start, 'inline').nil?
    if finish
      entry.merge!(state: field(finish, 'state'), status: field(finish, 'status'), acted: field(finish, 'acted'))
      PART_COUNTS.each { |key| entry[key.to_sym] = field(finish, key) }
    else
      entry[:state] = 'unfinished'
    end
    entry.compact
  end

  def edited
    event = named(COUNCIL_EDITED).last
    return unless event

    { language: field(event, 'language'), handoff: field(event, 'handoff'), reason: field(event, 'reason') }.compact
  end
end
