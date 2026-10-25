# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::Evals::RouterBenchmark::Report do
  def row(id, expected, got, confidence: 0.9, escalated: false, **extra)
    Captain::Evals::RouterBenchmark::Runner::Row.new(suite: 's', scenario_id: id, run: 1, mode: 'pipeline', model: 'm', expected: expected,
                                                     got: got, confidence: confidence, escalated: escalated, latency_ms: 400,
                                                     cost_usd: 0.001, **extra)
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

  it 'reports the traps, the confidence of wrong answers and what the escalation changed' do
    rows = [row('A11', 'route_agent_109', 'route_agent_109', trap: 'false_council'),
            row('A10', 'stay_current', 'route_agent_108', confidence: 0.6, trap: 'injection'),
            row('A03', 'route_agent_108', 'route_agent_108', escalated: true, first_choice: 'route_agent_77', escalation_ms: 900,
                                                             decided_by: 'escalation:openai/gpt-6-luna')]

    report = described_class.new(rows).to_h

    expect(report[:pipeline][:traps]).to include('false_council' => include(accuracy: 1.0), 'injection' => include(accuracy: 0.0))
    expect(report[:pipeline][:wrong_answers]).to include(count: 1, low_confidence: 1, confident: 0)
    expect(report[:pipeline][:escalation_detail]).to include(fired: 1, fixed: 1, broke: 0, latency: { p50: 900, p90: 900, max: 900 })
    expect(report[:pipeline][:answered_by]).to include('escalation:openai/gpt-6-luna (position -)' => 1)
    expect(report[:gate][:checks][:traps]).to be(false)
  end
end
