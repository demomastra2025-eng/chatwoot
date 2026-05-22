# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::Monitoring::PrometheusExporter do
  describe '#call' do
    it 'exports snapshot and release-gate data in Prometheus text format' do
      output = described_class.new(
        labels: { account_id: 1 },
        snapshot: {
          total_events: 5,
          request_count: 2,
          embedding_count: 1,
          transcription_count: 1,
          moderation_count: 1,
          blocked_count: 1,
          error_count: 1,
          provider_failure_count: 1,
          moderation_skipped_count: 0,
          schema_invalid_count: 1,
          tool_failure_count: 1,
          total_tokens: 300,
          all_total_tokens: 350,
          estimated_cost: BigDecimal('0.0012'),
          total_estimated_cost: BigDecimal('0.0015'),
          avg_duration_ms: 420.5,
          last_event_at: Time.zone.parse('2026-04-10 10:00:00'),
          by_feature: { 'assistant' => 2 },
          by_model: { 'gpt-4.1-mini' => 2 },
          by_provider: { 'openai' => 2 },
          by_event_name: { 'llm.chat.complete' => 2, 'llm.schema.invalid' => 1 },
          by_status: { 'completed' => 2 }
        },
        release_gate: { status: 'fail' },
        alerts: {
          active_count: 2,
          alerts: [
            { name: 'schema_invalid_rate', severity: 'warning' },
            { name: 'error_rate', severity: 'critical' }
          ]
        }
      ).call

      expect(output).to include('llm_events_total{account_id="1"} 5')
      expect(output).to include('llm_embeddings_total{account_id="1"} 1')
      expect(output).to include('llm_transcriptions_total{account_id="1"} 1')
      expect(output).to include('llm_moderation_checks_total{account_id="1"} 1')
      expect(output).to include('llm_estimated_cost_usd_total{account_id="1"} 0.0012')
      expect(output).to include('llm_all_estimated_cost_usd_total{account_id="1"} 0.0015')
      expect(output).to include('llm_provider_failures_total{account_id="1"} 1')
      expect(output).to include('llm_requests_by_feature_total{account_id="1",feature="assistant"} 2')
      expect(output).to include('llm_events_by_name_total{account_id="1",event_name="llm.chat.complete"} 2')
      expect(output).to include('llm_release_gate_status{account_id="1",status="fail"} 1')
      expect(output).to include('llm_release_gate_status{account_id="1",status="pass"} 0')
      expect(output).to include('llm_alerts_active_total{account_id="1"} 2')
      expect(output).to include('llm_alert_active{account_id="1",alert="schema_invalid_rate",severity="warning"} 1')
      expect(output).to include('llm_alert_active{account_id="1",alert="error_rate",severity="critical"} 1')
    end
  end
end
