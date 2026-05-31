# frozen_string_literal: true

require 'json'

class Llm::Evals::Scenario::JudgeResponse
  TRACE_TOOL_NAMES = %w[expand_trace grep_trace].freeze

  def initialize(response)
    @response = response
  end

  def call
    attributes = response_attributes
    verdict = normalize_verdict(attributes[:verdict])
    reasoning = attributes[:reasoning].to_s.presence || 'Judge client did not provide reasoning.'

    {
      verdict: verdict,
      reasoning: reasoning,
      passed_criteria: Array(attributes[:passed_criteria]).map(&:to_s),
      failed_criteria: Array(attributes[:failed_criteria]).map(&:to_s),
      trace_tool_calls: normalize_trace_tool_calls(attributes[:trace_tool_calls] || attributes[:tool_calls])
    }
  end

  private

  def response_attributes
    case @response
    when Hash
      @response.deep_symbolize_keys
    when String
      return { verdict: 'inconclusive', reasoning: 'Judge client returned non-JSON text.' } unless json_like?

      JSON.parse(@response).deep_symbolize_keys
    else
      @response.respond_to?(:to_h) ? @response.to_h.deep_symbolize_keys : {}
    end
  rescue JSON::ParserError
    { verdict: 'inconclusive', reasoning: 'Judge client returned non-JSON text.' }
  end

  def json_like?
    @response.to_s.strip.start_with?('{', '[')
  end

  def normalize_verdict(verdict)
    case verdict.to_s
    when 'pass'
      'success'
    when 'fail'
      'failure'
    when 'success', 'failure', 'continue', 'inconclusive'
      verdict.to_s
    else
      'inconclusive'
    end
  end

  def normalize_trace_tool_calls(calls)
    Array(calls).filter_map do |call|
      attributes = call.respond_to?(:to_h) ? call.to_h.deep_symbolize_keys : {}
      name = attributes[:name].presence || attributes[:tool_name].presence
      next unless TRACE_TOOL_NAMES.include?(name.to_s)

      arguments = attributes[:arguments].presence || attributes[:input].presence || {}
      { name: name.to_s, arguments: normalize_tool_arguments(arguments) }
    end
  end

  def normalize_tool_arguments(arguments)
    case arguments
    when String
      JSON.parse(arguments).deep_symbolize_keys
    else
      arguments.respond_to?(:to_h) ? arguments.to_h.deep_symbolize_keys : {}
    end
  rescue JSON::ParserError
    {}
  end
end
