# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::Monitoring::ReleaseGate do
  describe '#call' do
    let(:now) { Time.zone.parse('2026-04-10 12:00:00') }
    let(:date_range) { 24.hours.ago(now)..now }

    it 'rolls nine provider responses into their outer request without diluting its error rate or duplicating cost' do
      account = create(:account)
      create(:llm_event, account: account, created_at: 1.hour.ago(now), event_name: 'llm.chat.request',
                         request_id: 'synthetic-outer', error: true, duration_ms: 50, total_tokens: nil, estimated_cost: nil,
                         payload: { usage_scope: 'outer_request' })
      9.times do |index|
        create(:llm_event, account: account, created_at: 1.hour.ago(now), request_id: "synthetic-child-#{index}",
                           duration_ms: 100, estimated_cost: 0.001,
                           payload: { usage_scope: 'provider_response', parent_request_id: 'synthetic-outer' })
      end

      report = described_class.new(scope: LlmEvent.for_account(account.id), date_range: date_range, now: now,
                                    config: { min_request_count: 1 }).call

      expect(report.dig(:current_period, :metrics)).to include(request_count: 1, error_rate: 1.0,
                                                             avg_duration_ms: 50.0, p95_duration_ms: 50)
      expect(report.dig(:current_period, :metrics, :cost_per_request)).to eq(BigDecimal('0.009'))
      expect(report[:checks]).to include(include(name: 'error_rate', status: 'fail'))
    end

    it 'returns insufficient_data when the current window has too few requests' do
      create(:llm_event, created_at: 2.hours.ago(now))
      create(:llm_event, created_at: 1.hour.ago(now))

      report = described_class.new(
        date_range: date_range,
        now: now
      ).call

      expect(report[:status]).to eq('insufficient_data')
      expect(report.dig(:current_period, :metrics, :request_count)).to eq(2)
    end

    it 'passes when the current window stays within thresholds' do
      12.times do |index|
        create(
          :llm_event,
          duration_ms: 300 + index,
          estimated_cost: 0.0002,
          created_at: 2.hours.ago(now) + index.minutes
        )
      end

      12.times do |index|
        create(
          :llm_event,
          duration_ms: 250 + index,
          estimated_cost: 0.00015,
          created_at: 26.hours.ago(now) + index.minutes
        )
      end

      report = described_class.new(
        date_range: date_range,
        now: now,
        config: { min_request_count: 10 }
      ).call

      expect(report[:status]).to eq('pass')
      expect(report[:checks].map { |check| check[:status] }).not_to include('fail')
    end

    it 'fails when schema validity and latency regress beyond the configured gate' do
      10.times do |index|
        create(
          :llm_event,
          trace_id: "trace-current-#{index}",
          duration_ms: 4_000 + index,
          estimated_cost: 0.0003,
          created_at: 2.hours.ago(now) + index.minutes
        )
      end
      create(
        :llm_event,
        event_name: 'llm.schema.invalid',
        trace_id: 'trace-current-0',
        schema_invalid: true,
        created_at: 90.minutes.ago(now)
      )

      10.times do |index|
        create(
          :llm_event,
          trace_id: "trace-previous-#{index}",
          duration_ms: 500 + index,
          estimated_cost: 0.0001,
          created_at: 26.hours.ago(now) + index.minutes
        )
      end

      report = described_class.new(
        date_range: date_range,
        now: now,
        config: {
          min_request_count: 10,
          max_avg_duration_ms: 2_000,
          max_schema_invalid_rate: 0.01,
          max_avg_duration_regression: 1.2
        }
      ).call

      expect(report[:status]).to eq('fail')
      expect(report[:checks]).to include(
        include(name: 'schema_invalid_rate', status: 'fail'),
        include(name: 'avg_duration_ms', status: 'fail'),
        include(name: 'avg_duration_regression', status: 'fail')
      )
    end

    it 'fails on provider failures and payload-budget truncation rates' do
      10.times do |index|
        create(
          :llm_event,
          event_name: 'llm.chat.complete',
          request_id: "request-#{index}",
          trace_id: "trace-#{index}",
          created_at: 2.hours.ago(now) + index.minutes
        )
      end
      create(
        :llm_event,
        event_name: 'llm.chat.complete',
        request_id: 'request-provider-failure',
        trace_id: 'trace-provider-failure',
        error: true,
        error_code: 'provider_unavailable',
        created_at: 90.minutes.ago(now)
      )
      create(
        :llm_event,
        event_name: 'llm.tool.complete',
        payload_truncated: true,
        created_at: 85.minutes.ago(now)
      )

      report = described_class.new(
        date_range: date_range,
        now: now,
        config: {
          min_request_count: 10,
          max_provider_failure_rate: 0.01,
          max_payload_truncated_rate: 0.01
        }
      ).call

      expect(report[:status]).to eq('fail')
      expect(report.dig(:current_period, :metrics)).to include(
        provider_failure_rate: 1.0 / 12.0,
        payload_truncated_rate: 1.0 / 12.0
      )
      expect(report[:checks]).to include(
        include(name: 'provider_failure_rate', status: 'fail'),
        include(name: 'payload_truncated_rate', status: 'fail')
      )
    end

    it 'evaluates error rate per request instead of diluting it across child events' do
      create(
        :llm_event,
        event_name: 'llm.chat.complete',
        request_id: 'request-1',
        trace_id: 'trace-1',
        error: true,
        duration_ms: 500,
        estimated_cost: 0.001,
        created_at: 2.hours.ago(now)
      )
      8.times do |index|
        create(
          :llm_event,
          event_name: 'llm.tool.complete',
          request_id: 'request-1',
          trace_id: 'trace-1',
          error: false,
          created_at: 2.hours.ago(now) + index.minutes
        )
      end
      11.times do |index|
        create(
          :llm_event,
          event_name: 'llm.chat.complete',
          request_id: "request-pass-#{index}",
          trace_id: "trace-pass-#{index}",
          error: false,
          duration_ms: 300,
          estimated_cost: 0.001,
          created_at: 90.minutes.ago(now) + index.minutes
        )
      end

      report = described_class.new(
        date_range: date_range,
        now: now,
        config: {
          min_request_count: 10,
          max_error_rate: 0.05
        }
      ).call

      expect(report[:status]).to eq('fail')
      expect(report.dig(:current_period, :metrics, :request_count)).to eq(12)
      expect(report.dig(:current_period, :metrics, :error_rate)).to eq(1.0 / 12.0)
      expect(report[:checks]).to include(
        include(name: 'error_rate', status: 'fail')
      )
    end

    it 'correlates child events by request_id when trace_id is missing' do
      create(
        :llm_event,
        event_name: 'llm.chat.complete',
        request_id: 'request-1',
        duration_ms: 500,
        estimated_cost: 0.001,
        created_at: 2.hours.ago(now)
      )
      create(
        :llm_event,
        event_name: 'llm.schema.invalid',
        request_id: 'request-1',
        schema_invalid: true,
        created_at: 119.minutes.ago(now)
      )
      11.times do |index|
        create(
          :llm_event,
          event_name: 'llm.chat.complete',
          request_id: "request-pass-#{index}",
          duration_ms: 300,
          estimated_cost: 0.001,
          created_at: 90.minutes.ago(now) + index.minutes
        )
      end

      report = described_class.new(
        date_range: date_range,
        now: now,
        config: {
          min_request_count: 10,
          max_schema_invalid_rate: 0.05
        }
      ).call

      expect(report[:status]).to eq('fail')
      expect(report.dig(:current_period, :metrics, :request_count)).to eq(12)
      expect(report.dig(:current_period, :metrics, :schema_invalid_rate)).to eq(1.0 / 12.0)
      expect(report[:checks]).to include(
        include(name: 'schema_invalid_rate', status: 'fail')
      )
    end

    it 'returns disabled when the gate is turned off' do
      create(:llm_event, created_at: 1.hour.ago(now))

      report = described_class.new(
        date_range: date_range,
        now: now,
        config: { enabled: false }
      ).call

      expect(report[:status]).to eq('disabled')
      expect(report[:checks]).to eq([])
    end
  end
end
