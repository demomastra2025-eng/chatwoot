# frozen_string_literal: true

class Llm::Evals::Scenario::Result
  attr_reader :id, :description, :tags, :expected, :state, :failures, :duration_ms

  def initialize(**attributes)
    @id = attributes.fetch(:id)
    @description = attributes[:description]
    @tags = Array(attributes[:tags])
    @expected = attributes.fetch(:expected).to_h.deep_symbolize_keys
    @state = attributes.fetch(:state)
    @failures = Array(attributes[:failures])
    @duration_ms = attributes[:duration_ms]
  end

  def status
    failures.empty? && state.terminal_status != 'fail' ? 'pass' : 'fail'
  end

  def success?
    status == 'pass'
  end

  def to_case_result
    {
      id: id,
      description: description,
      tags: tags,
      status: status,
      expected: expected,
      actual: state.summary,
      failures: failures,
      reasoning: state.terminal_reason,
      duration_ms: duration_ms
    }.compact
  end
end
