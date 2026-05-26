# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::EvalRun do
  let(:account) { create(:account) }

  it 'omits full result from default summaries and returns compact result metadata' do
    run = described_class.create!(
      account: account,
      status: 'passed',
      mode: 'evals',
      pack_ids: ['captain.ai_voice_trace'],
      result: {
        suites: [
          { suite_id: 'captain.ai_voice_trace', status: 'pass', cases: [{ input: 'sensitive prompt' }] },
          { suite_id: 'captain.tool_safety', status: 'fail', cases: [{ input: 'unsafe tool args' }] }
        ]
      }
    )

    summary = run.summary

    expect(summary).not_to include(:result)
    expect(summary[:result_summary]).to include(
      suite_count: 2,
      passed_count: 1,
      failed_count: 1,
      suite_ids: ['captain.ai_voice_trace', 'captain.tool_safety']
    )
  end

  it 'can include full result for explicit run-status lookups' do
    run = described_class.create!(
      account: account,
      status: 'passed',
      mode: 'evals',
      pack_ids: ['captain.ai_voice_trace'],
      result: { suites: [{ suite_id: 'captain.ai_voice_trace', status: 'pass' }] }
    )

    expect(run.summary(include_result: true)[:result]).to eq('suites' => [{ 'suite_id' => 'captain.ai_voice_trace', 'status' => 'pass' }])
  end

  it 'compacts stored eval results to counters without raw case payloads' do
    compact = described_class.compact_result(
      status: 'fail',
      suite_count: 1,
      total_count: 2,
      passed_count: 1,
      failed_count: 1,
      error_count: 0,
      suites: [
        {
          suite_id: 'captain.conversation_completion',
          status: 'fail',
          prompt_id: 'conversation_completion',
          prompt_sha: 'abc123',
          model: 'gpt-test',
          total_count: 2,
          passed_count: 1,
          failed_count: 1,
          error_count: 0,
          pass_rate: 0.5,
          cases: [{ id: 'case-1', input: 'secret customer prompt', output: 'raw answer' }]
        }
      ]
    )

    expect(compact).to include(
      status: 'fail',
      suite_count: 1,
      total_count: 2,
      passed_count: 1,
      failed_count: 1,
      error_count: 0
    )
    expect(compact[:suites]).to eq(
      [
        {
          suite_id: 'captain.conversation_completion',
          status: 'fail',
          prompt_id: 'conversation_completion',
          prompt_sha: 'abc123',
          model: 'gpt-test',
          total_count: 2,
          passed_count: 1,
          failed_count: 1,
          error_count: 0,
          pass_rate: 0.5
        }
      ]
    )
    expect(compact.to_json).not_to include('secret customer prompt')
    expect(compact.to_json).not_to include('raw answer')
    expect(compact.to_json).not_to include('cases')
  end
end
