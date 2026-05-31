# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::Evals::CollectionResult do
  it 'aggregates suite-level pass and failure counts' do
    suite_one = instance_double(
      Llm::Evals::Result,
      total_count: 2,
      passed_count: 2,
      failed_count: 0,
      error_count: 0,
      passed?: true,
      to_h: { suite_id: 'one' }
    )
    suite_two = instance_double(
      Llm::Evals::Result,
      total_count: 3,
      passed_count: 1,
      failed_count: 1,
      error_count: 1,
      passed?: false,
      to_h: { suite_id: 'two' }
    )

    result = described_class.new(suites: [suite_one, suite_two])

    expect(result.to_h).to include(
      status: 'fail',
      suite_count: 2,
      total_count: 5,
      passed_count: 3,
      failed_count: 1,
      error_count: 1,
      pass_rate: 0.6,
      suites: [{ suite_id: 'one' }, { suite_id: 'two' }]
    )
  end

  it 'summarizes failed scenarios, duration, and estimated cost for reporting UIs' do
    suite = Llm::Evals::Result.new(
      suite_id: 'captain.scenarios',
      prompt_id: nil,
      prompt_sha: nil,
      model: nil,
      cases: [
        {
          id: 'openrouter.reasoning_presence',
          status: 'pass',
          duration_ms: 10,
          artifact: { usage: { estimated_cost: 0.00001 } }
        },
        {
          id: 'openrouter.tool_no_final_answer',
          status: 'fail',
          duration_ms: 25,
          failures: ['assistant response missing after last user message'],
          artifact: { usage: { estimated_cost: 0.00003 } }
        }
      ]
    )

    result = described_class.new(suites: [suite]).to_h

    expect(result).to include(
      pass_rate: 0.5,
      duration_ms: 35,
      estimated_cost: 0.00004,
      failed_scenarios: [
        include(
          suite_id: 'captain.scenarios',
          id: 'openrouter.tool_no_final_answer',
          status: 'fail',
          duration_ms: 25,
          failures: ['assistant response missing after last user message']
        )
      ]
    )
  end
end
