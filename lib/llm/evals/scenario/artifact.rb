# frozen_string_literal: true

class Llm::Evals::Scenario::Artifact
  class << self
    def build(result:, trace_events: [])
      case_result = result.respond_to?(:to_case_result) ? result.to_case_result : result.to_h
      trace_digest = trace_digest_for(trace_events)

      {
        case_id: case_result[:id],
        status: case_result[:status],
        failures: case_result[:failures],
        reasoning: case_result[:reasoning],
        summary: actual_summary(case_result[:actual]),
        timeline: timeline_for(result),
        trace_digest: trace_digest,
        usage: usage_for(trace_digest)
      }.compact
    end

    private

    def timeline_for(result)
      return unless result.respond_to?(:state)

      Llm::Evals::Scenario::Timeline.new(state: result.state).call
    end

    def trace_digest_for(trace_events)
      Llm::Evals::TraceDigest.new(events: trace_events).call
    end

    def usage_for(trace_digest)
      events = Array(trace_digest[:events])

      {
        providers: events.filter_map { |event| event[:provider] }.uniq,
        models: events.filter_map { |event| event[:model] }.uniq,
        token_totals: trace_digest[:token_totals],
        estimated_cost: trace_digest[:estimated_cost],
        openrouter_generation_ids: trace_digest[:openrouter_generation_ids]
      }.compact
    end

    def actual_summary(actual)
      payload = actual.respond_to?(:to_h) ? actual.to_h.deep_symbolize_keys : {}
      tool_events = Array(payload[:tool_events])

      {
        thread_id: payload[:thread_id],
        turn_count: payload[:turn_count],
        tool_events_count: tool_events.size,
        tool_names: tool_events.filter_map { |event| event.to_h.deep_symbolize_keys[:tool_name] }.uniq,
        ui_action_types: Array(payload[:ui_action_types]),
        reasoning_present: payload[:reasoning_present],
        openrouter_generation_ids: Array(payload[:openrouter_generation_ids]),
        terminal_status: payload[:terminal_status],
        terminal_reason: payload[:terminal_reason],
        duplicate_mutations: Array(payload[:duplicate_mutations])
      }.compact
    end
  end
end
