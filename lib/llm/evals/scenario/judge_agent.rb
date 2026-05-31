# frozen_string_literal: true

class Llm::Evals::Scenario::JudgeAgent < Llm::Evals::Scenario::AgentAdapter
  def initialize(**attributes)
    super(role: :judge, name: attributes.fetch(:name, 'ScenarioJudge'))

    @criteria = normalize_criteria(attributes[:criteria])
    @expected = attributes.fetch(:expected, {}).to_h.deep_symbolize_keys
    @client = cached_client(attributes)
    @trace_events = attributes[:trace_events]
    @terminal_on_pass = attributes.fetch(:terminal_on_pass, true)
    @terminal_on_failure = attributes.fetch(:terminal_on_failure, true)
    @trace_tool_iterations = attributes.fetch(:trace_tool_iterations, 2).to_i.clamp(0, 5)
  end

  def call(input)
    local_failures = deterministic_failures(input)
    return deterministic_failure_output(local_failures) if local_failures.present? && @terminal_on_failure
    return deterministic_success_output if local_failures.empty? && deterministic_only?
    return missing_client_output(local_failures) unless @client.callable?

    client_output(input, local_failures)
  rescue StandardError => e
    judge_output(
      verdict: 'inconclusive',
      reasoning: "Judge agent failed: #{e.class.name}",
      details: { error_class: e.class.name, error_message: e.message }
    )
  end

  private

  def deterministic_failures(input)
    return [] if @expected.blank?

    Llm::Evals::Scenario::ExpectationEvaluator.new(state: input.state, expected: @expected).call
  end

  def deterministic_only?
    @expected.present? && @criteria.blank? && !@client.callable?
  end

  def deterministic_failure_output(failures)
    judge_output(
      verdict: terminal_verdict('failure'),
      reasoning: failures.join('; '),
      details: { deterministic_failures: failures }
    )
  end

  def deterministic_success_output
    judge_output(
      verdict: terminal_verdict('success'),
      reasoning: 'Scenario expectations passed.',
      details: { deterministic_passed: true }
    )
  end

  def missing_client_output(local_failures)
    judge_output(
      verdict: 'inconclusive',
      reasoning: missing_client_reason(local_failures),
      details: { deterministic_failures: local_failures, criteria: @criteria }
    )
  end

  def missing_client_reason(local_failures)
    return "Deterministic checks are not terminal yet: #{local_failures.join('; ')}" if local_failures.present?
    return 'Judge criteria require a client, but no client was configured.' if @criteria.present?

    'No judge criteria or expected checks were configured.'
  end

  def client_output(input, local_failures)
    trace_tool_results = []
    normalized_response = nil

    (@trace_tool_iterations + 1).times do
      response = @client.call(judge_request(input, local_failures, trace_tool_results: trace_tool_results))
      normalized_response = normalize_response(response)
      trace_tool_calls = normalized_response[:trace_tool_calls]
      break if trace_tool_calls.blank? || (trace_tool_results.present? && trace_tool_results.last[:terminal] == true)

      trace_tool_results.concat(execute_trace_tool_calls(input, trace_tool_calls))
    end

    normalized_response ||= { verdict: 'inconclusive', reasoning: 'Judge client did not return a verdict.' }

    judge_output(
      verdict: terminal_verdict(normalized_response[:verdict]),
      reasoning: normalized_response[:reasoning],
      details: normalized_response.merge(
        deterministic_failures: local_failures,
        trace_tool_results_count: trace_tool_results.size
      ).compact
    )
  end

  def judge_request(input, local_failures, trace_tool_results: [])
    Llm::Evals::Scenario::JudgeRequest.new(
      input: input,
      criteria: @criteria,
      expected: @expected,
      deterministic_failures: local_failures,
      trace_events: @trace_events,
      trace_tool_results: trace_tool_results
    ).call
  end

  def normalize_response(response)
    Llm::Evals::Scenario::JudgeResponse.new(response).call
  end

  def execute_trace_tool_calls(input, calls)
    Llm::Evals::Scenario::JudgeTraceToolExecutor.new(events: trace_events_for(input)).call(calls)
  end

  def trace_events_for(input)
    @trace_events || Array(input.trace_events).presence || input.state.events
  end

  def terminal_verdict(verdict)
    case verdict.to_s
    when 'success'
      @terminal_on_pass ? 'success' : 'continue'
    when 'failure'
      @terminal_on_failure ? 'failure' : 'continue'
    else
      verdict.to_s
    end
  end

  def judge_output(verdict:, reasoning:, details:)
    Llm::Evals::Scenario::AgentAdapter::Output.new(
      messages: [{ role: 'judge', content: reasoning }],
      events: [
        {
          action: 'judge_evaluation',
          name: 'scenario.judge.evaluation',
          judge: name,
          verdict: verdict,
          criteria_count: @criteria.size,
          details: details
        }.compact
      ],
      verdict: verdict,
      reasoning: reasoning
    )
  end

  def normalize_criteria(criteria)
    Array(criteria).map.with_index(1) do |criterion, index|
      attributes = criterion.respond_to?(:to_h) ? criterion.to_h.deep_symbolize_keys : { description: criterion.to_s }
      attributes[:id] ||= "criterion_#{index}"
      attributes.compact
    end
  end

  def cached_client(attributes)
    Llm::Evals::Scenario::CachedClient.new(
      client: attributes[:client],
      cache: attributes[:cache] || Llm::Evals::Scenario::ClientCache.new(
        cache_key: attributes[:cache_key],
        store: attributes[:cache_store],
        namespace: attributes.fetch(:cache_namespace, 'judge'),
        mode: attributes.fetch(:cache_mode, :read_write)
      )
    )
  end
end
