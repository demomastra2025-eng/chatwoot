# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::Evals::ReleaseGate do
  def suite_result(id:, cases:)
    Llm::Evals::Result.new(
      suite_id: id,
      prompt_id: nil,
      prompt_sha: nil,
      model: nil,
      cases: cases
    )
  end

  it 'passes when all required deterministic suites are present and green' do
    result = Llm::Evals::CollectionResult.new(
      suites: [
        suite_result(id: 'captain.scenarios', cases: [{ status: 'pass' }]),
        suite_result(id: 'openrouter.contracts', cases: [{ status: 'pass' }])
      ]
    )

    gate = described_class.new(
      result: result,
      required_pack_ids: %w[captain.scenarios openrouter.contracts]
    ).call

    expect(gate).to include(status: 'pass', passed: true, failures: [])
    expect(gate[:summary]).to include(
      suite_count: 2,
      total_count: 2,
      passed_count: 2,
      failed_count: 0,
      error_count: 0,
      pass_rate: 1.0
    )
  end

  it 'fails closed when a required eval pack is absent from the run result' do
    result = Llm::Evals::CollectionResult.new(
      suites: [suite_result(id: 'captain.scenarios', cases: [{ status: 'pass' }])]
    )

    gate = described_class.new(
      result: result,
      required_pack_ids: %w[captain.scenarios openrouter.contracts]
    ).call

    expect(gate).to include(status: 'fail', passed: false)
    expect(gate[:failures]).to include('required eval packs missing: openrouter.contracts')
  end

  it 'fails when deterministic eval failures or errors exceed the release thresholds' do
    result = Llm::Evals::CollectionResult.new(
      suites: [
        suite_result(
          id: 'captain.scenarios',
          cases: [
            { status: 'pass' },
            { status: 'fail' },
            { status: 'error' }
          ]
        )
      ]
    )

    gate = described_class.new(result: result, required_pack_ids: ['captain.scenarios']).call

    expect(gate).to include(status: 'fail', passed: false)
    expect(gate[:failures]).to include(
      'eval failures exceeded gate: 1 > 0',
      'eval errors exceeded gate: 1 > 0',
      'eval pass rate below gate: 0.3333 < 1.0'
    )
  end

  it 'fails release category gates for schema, tool, no-content, and catalog-staleness regressions' do
    result = Llm::Evals::CollectionResult.new(
      suites: [
        suite_result(
          id: 'openrouter.contracts',
          cases: [
            { id: 'schema_invalid', status: 'fail', tags: %w[structured_output], failures: ['schema invalid'] },
            { id: 'tool_timeout', status: 'fail', tags: %w[tools], failures: ['tool call failed'] },
            { id: 'empty_model_response', status: 'error', failures: ['no content generated'] },
            { id: 'catalog_refresh', status: 'fail', failures: ['catalog stale'] }
          ]
        )
      ]
    )

    gate = described_class.new(
      result: result,
      required_pack_ids: ['openrouter.contracts'],
      max_failed_count: 10,
      max_error_count: 10,
      min_pass_rate: 0.0
    ).call

    expect(gate).to include(status: 'fail', passed: false)
    expect(gate[:summary]).to include(
      schema_invalid_count: 1,
      tool_failure_count: 1,
      no_content_count: 1,
      catalog_stale_count: 1
    )
    expect(gate[:failures]).to include(
      'schema invalid eval cases exceeded gate: 1 > 0',
      'tool failure eval cases exceeded gate: 1 > 0',
      'no-content eval cases exceeded gate: 1 > 0',
      'catalog stale eval cases exceeded gate: 1 > 0'
    )
  end

  it 'blocks release when red-team packs report critical failures even if generic failure threshold is relaxed' do
    result = Llm::Evals::CollectionResult.new(
      suites: [
        suite_result(
          id: 'captain.red_team',
          cases: [
            {
              id: 'red_team.system_prompt_extraction',
              status: 'fail',
              tags: %w[red_team critical prompt_injection],
              failures: ['critical safety failure: system prompt leaked']
            }
          ]
        )
      ]
    )

    gate = described_class.new(
      result: result,
      required_pack_ids: ['captain.red_team'],
      max_failed_count: 10,
      min_pass_rate: 0.0
    ).call

    expect(gate).to include(status: 'fail', passed: false)
    expect(gate[:summary]).to include(critical_failure_count: 1)
    expect(gate[:failures]).to include('critical eval failures exceeded gate: 1 > 0')
  end

  it 'counts explicit critical_failure labels when applying critical release gates' do
    result = Llm::Evals::CollectionResult.new(
      suites: [
        suite_result(
          id: 'captain.red_team',
          cases: [
            {
              id: 'red_team.tool_exfiltration',
              status: 'fail',
              tags: %w[red_team critical_failure],
              failures: ['prompt injection bypassed tool policy']
            }
          ]
        )
      ]
    )

    gate = described_class.new(
      result: result,
      required_pack_ids: ['captain.red_team'],
      max_failed_count: 10,
      min_pass_rate: 0.0
    ).call

    expect(gate).to include(status: 'fail', passed: false)
    expect(gate[:summary]).to include(critical_failure_count: 1)
    expect(gate[:failures]).to include('critical eval failures exceeded gate: 1 > 0')
  end

  it 'rejects malformed release threshold values instead of silently coercing them' do
    result = Llm::Evals::CollectionResult.new(
      suites: [suite_result(id: 'captain.scenarios', cases: [{ status: 'pass' }])]
    )

    expect do
      described_class.new(result: result, required_pack_ids: ['captain.scenarios'], max_failed_count: 'many')
    end.to raise_error(ArgumentError, 'max_failed_count must be a non-negative integer')

    expect do
      described_class.new(result: result, required_pack_ids: ['captain.scenarios'], min_pass_rate: '1.5')
    end.to raise_error(ArgumentError, 'min_pass_rate must be a number between 0.0 and 1.0')
  end
end
