# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::Monitoring::AlertEvaluator do
  describe '#call' do
    it 'returns alerting with active alerts for failed checks' do
      report = described_class.new(
        release_gate_report: {
          status: 'fail',
          evaluated_at: Time.zone.parse('2026-04-10 12:00:00'),
          checks: [
            { name: 'error_rate', status: 'fail', actual: 0.2, expected: 0.05, message: 'Too many errors.' },
            { name: 'provider_failure_rate', status: 'fail', actual: 0.2, expected: 0.05, message: 'Provider down.' },
            { name: 'payload_truncated_rate', status: 'fail', actual: 0.1, expected: 0.05, message: 'Payload summaries too large.' },
            { name: 'schema_invalid_rate', status: 'fail', actual: 0.1, expected: 0.02, message: 'Too many schema failures.' },
            { name: 'avg_duration_ms', status: 'pass', actual: 300, expected: 500 }
          ]
        }
      ).call

      expect(report).to include(
        status: 'alerting',
        release_gate_status: 'fail',
        active_count: 4
      )
      expect(report[:alerts]).to contain_exactly(
        include(name: 'error_rate', severity: 'critical', status: 'firing'),
        include(name: 'provider_failure_rate', severity: 'critical', status: 'firing'),
        include(name: 'payload_truncated_rate', severity: 'warning', status: 'firing'),
        include(name: 'schema_invalid_rate', severity: 'warning', status: 'firing')
      )
    end

    it 'returns insufficient_data without active alerts when the gate has too little traffic' do
      report = described_class.new(
        release_gate_report: {
          status: 'insufficient_data',
          checks: []
        }
      ).call

      expect(report).to include(
        status: 'insufficient_data',
        release_gate_status: 'insufficient_data',
        active_count: 0,
        alerts: []
      )
    end
  end
end
