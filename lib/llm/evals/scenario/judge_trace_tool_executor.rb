# frozen_string_literal: true

class Llm::Evals::Scenario::JudgeTraceToolExecutor
  def initialize(events:)
    @events = events
  end

  def call(calls)
    tools = Llm::Evals::TraceTools.new(events: @events)

    calls.map do |call|
      result = execute_tool_call(tools, call)
      { name: call[:name], arguments: call[:arguments], result: result }.compact
    rescue StandardError => e
      { name: call[:name], arguments: call[:arguments], error: "#{e.class.name}: #{e.message}", terminal: true }
    end
  end

  private

  def execute_tool_call(tools, call)
    arguments = (call[:arguments] || {}).to_h.deep_symbolize_keys

    case call[:name].to_s
    when 'expand_trace'
      tools.expand_trace(index: arguments[:index], event_name: arguments[:event_name], limit: arguments[:limit])
    when 'grep_trace'
      tools.grep_trace(query: arguments[:query], fields: arguments[:fields], limit: arguments[:limit])
    end
  end
end
