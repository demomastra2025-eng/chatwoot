# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::Evals::RouterBenchmark::Report do
  def row(id, expected, got, confidence: 0.9, **extra)
    item = Captain::Evals::RouterBenchmark::Runner::Row.new(suite: 's', scenario_id: id, run: 1, mode: 'pipeline', model: 'm', expected: expected,
                                                            got: got, confidence: confidence, latency_ms: 400, cost_usd: 0.001)
    extra.each { |name, value| item[name] = value }
    item
  end

  it 'counts false councils, exact councils, human recall and calibration' do
    rows = [row('A11', 'route_agent_109', 'council_108_109'), row('A04', 'council_77_109', 'council_77_109'),
            row('A09', 'council_77_108_109', 'council_77_109', confidence: 0.7), row('A07', 'human_handoff', 'human_handoff')]

    metrics = described_class.new(rows).to_h[:pipeline]

    expect(metrics[:councils]).to include(false_council_rate: 1.0, exact_set_rate: 0.5, missed_council_rate: 0.0)
    expect(metrics[:councils][:participant_recall]).to eq(0.8)
    expect(metrics[:human]).to include(recall: 1.0, false_human: 0)
    expect(metrics[:calibration]['<0.75']).to eq(count: 1, accuracy: 0.0)
    expect(described_class.new(rows).to_h[:gate][:verdict]).to eq('FAIL')
    expect(described_class.new(rows).markdown).to include('| pipeline | 50.0% |')
  end

  it 'reports the traps, the confidence of wrong answers and which model of the chain answered' do
    rows = [row('A11', 'route_agent_109', 'route_agent_109', trap: 'false_council'),
            row('A10', 'stay_current', 'route_agent_108', confidence: 0.6, trap: 'injection'),
            row('A12', 'stay_current', 'route_agent_77', confidence: 0.95),
            row('A03', 'route_agent_108', 'route_agent_108', decided_by: 'inception/mercury-decide', chain_position: 2)]

    report = described_class.new(rows).to_h

    expect(report[:pipeline][:traps]).to include('false_council' => include(accuracy: 1.0), 'injection' => include(accuracy: 0.0))
    expect(report[:pipeline][:wrong_answers]).to eq(count: 2, low_confidence: 1, confident: 1)
    expect(report[:pipeline]).to include(chain_fallbacks: 1)
    expect(report[:pipeline][:answered_by]).to include('inception/mercury-decide (position 2)' => 1, 'm (position -)' => 3)
    expect(report[:gate][:checks]).to include(traps: false).and(satisfy { |checks| !checks.key?(:escalation_rate) })
    expect(described_class.new(rows).markdown).to include('| 2 (1/1) |')
    expect(described_class.new(rows).markdown).not_to include('Escalation')
  end
end
