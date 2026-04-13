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
      suites: [{ suite_id: 'one' }, { suite_id: 'two' }]
    )
  end
end
