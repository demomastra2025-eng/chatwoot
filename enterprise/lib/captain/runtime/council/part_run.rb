# frozen_string_literal: true

# One council part as a normal run of the agent that owns it: its own prompt and its own tools (see PartTools), the customer's
# fragment as the input, a structured result (PartSchema). It persists nothing; the caller records the outcome.
#
# Whether an action was performed is computed here from the tool results of the run, never taken from what the model says:
# `acted` means at least one successful (or provider-pending) result of a mutating tool that is not an annotation. A technical
# failure of a tool stops the run (see ToolWrapper) and comes back as `technical`.
#
# The result is a plain Hash. No ActiveRecord object leaves the call, so it can cross a thread boundary.
class Captain::Runtime::Council::PartRun
  STATUSES = Captain::Runtime::PartSchema::STATUSES
  SUMMARY_LIMIT = 300

  # Counts what the tools of one run did. It belongs to one run and one thread.
  class Tracker
    attr_reader :tools_called, :turns, :mutations_succeeded, :mutations_failed, :mutations_unknown, :notes

    def initialize(mutating_names)
      @mutating = mutating_names.to_set
      @tools_called = @turns = @mutations_succeeded = @mutations_failed = @mutations_unknown = 0
      @pending = false
      @notes = []
    end

    def tool_complete(tool_name, result)
      @tools_called += 1
      return unless @mutating.include?(tool_name.to_s) && !Captain::Runtime::ToolFailure.annotation_tool?(tool_name)

      case Captain::Runtime::ToolFailure.outcome(result)
      when Captain::Runtime::ToolFailure::SUCCESS then succeeded(tool_name, result)
      when Captain::Runtime::ToolFailure::NOT_EXECUTED then @mutations_failed += 1
      else @mutations_unknown += 1
      end
    end

    def llm_call
      @turns += 1
    end

    def acted?
      @mutations_succeeded.positive?
    end

    def pending?
      @pending
    end

    # What the successful actions returned, as far as it is needed when the part ended without a text of its own.
    def summary
      @notes.join('; ').first(Captain::Runtime::PartRegistry::SUMMARY_LIMIT)
    end

    private

    def succeeded(tool_name, result)
      @mutations_succeeded += 1
      @pending ||= Captain::Runtime::ToolFailure.pending?(result)
      rendered = Captain::ToolResult.render(result).to_s.squish.first(SUMMARY_LIMIT)
      @notes << "#{Captain::Runtime::ToolFailure.canonical_name(tool_name)}: #{rendered}"
    end
  end

  attr_reader :tracker

  # agent: built on the calling thread from the owner's runtime with the tools of PartTools. snapshot: the part's own context.
  # callbacks: the callbacks of the run (already safe to call from several threads).
  def initialize(agent:, snapshot:, account:, llm_context:, callbacks:, max_turns:)
    @agent, @snapshot, @account, @llm_context, @callbacks, @max_turns = agent, snapshot, account, llm_context, callbacks, max_turns
    @tracker = Tracker.new(@agent.tools.select { |tool| Llm::ToolRiskPolicy.mutating?(tool) }.map { |tool| tool.name.to_s })
  end

  # Raises Captain::Conversation::ControlGenerationStaleError when the run is no longer current; #tracker then still holds what
  # the run did up to that point.
  def call(fragment)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = Captain::Runtime::Runner.new.run(
      @agent, fragment, context: @snapshot, account: @account, llm_context: @llm_context, max_turns: @max_turns,
                        callbacks: tracked_callbacks
    )
    outcome(result, ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round)
  end

  def self.parse_output(raw)
    parsed = raw.is_a?(Hash) ? raw.deep_stringify_keys : JSON.parse(raw.to_s)
    parsed = JSON.parse(parsed['response']) if parsed.is_a?(Hash) && parsed['status'].blank? && parsed['response'].is_a?(String)
    return unless parsed.is_a?(Hash) && STATUSES.include?(parsed['status'].to_s.strip)

    {
      'status' => parsed['status'].to_s.strip, 'patient_language' => text_of(parsed['patient_language']),
      'customer_text' => text_of(parsed['customer_text']),
      'questions' => strings_of(parsed['questions']), 'sources' => strings_of(parsed['sources']),
      'suggested_agent' => text_of(parsed['suggested_agent']), 'reasoning' => text_of(parsed['reasoning'])
    }
  rescue JSON::ParserError
    nil
  end

  def self.text_of(value)
    value.is_a?(String) ? value.strip : ''
  end

  def self.strings_of(value)
    return [] unless value.is_a?(Array)

    value.filter_map { |item| item.strip.presence if item.is_a?(String) }
  end

  private

  def tracked_callbacks
    merged = @callbacks.to_h.transform_values { |list| Array(list).dup }
    (merged[:tool_complete] ||= []) << ->(tool_name, result, *) { @tracker.tool_complete(tool_name, result) }
    (merged[:llm_call_complete] ||= []) << ->(*) { @tracker.llm_call }
    merged
  end

  def outcome(result, duration_ms)
    context = result.context || {}
    technical = context[:technical_failure].presence
    technical ||= { 'kind' => Captain::Runtime::ToolFailure::TECHNICAL, 'reason' => 'run_error', 'error_class' => result.error.class.name } if result.error
    output = self.class.parse_output(result.output) unless technical
    # A part that did nothing and gave no usable answer (the model or the schema failed) is a technical failure, as the same
    # output of a single agent is a failed turn: the other parts are answered and the conversation goes to staff. A part that
    # acted is still reported as done.
    technical ||= { 'kind' => Captain::Runtime::ToolFailure::TECHNICAL, 'reason' => 'invalid_output' } if output.nil? && !@tracker.acted?
    {
      output: output, acted: @tracker.acted?, pending: @tracker.pending?,
      technical: technical, summary: @tracker.summary, duration_ms: duration_ms, tracking: tracking_of(context),
      mutations_succeeded: @tracker.mutations_succeeded, mutations_failed: @tracker.mutations_failed,
      mutations_unknown: @tracker.mutations_unknown, tools_called: @tracker.tools_called, turns: @tracker.turns
    }
  end

  # What the main run must know about the tools this run called (retry safety, error fallbacks, attachments). The appointment
  # evidence is left out: it would make the whole council reply look like a deferred reschedule.
  def tracking_of(context)
    {
      completed_tool_names: Array(context[:captain_v2_completed_tool_names]),
      completed_actions: Array(context[Captain::Runtime::ToolWrapper::COMPLETED_ACTIONS_KEY]),
      completed_tool_results: Array(context[:captain_v2_completed_tool_results]).map { |record| record.to_h.except(:appointment_evidence) },
      artifact_ids: Array(context[:captain_v2_artifact_ids])
    }
  end
end
