# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::Monitoring::TimeSeriesSnapshot do
  it 'keeps outer request latency and errors while counting native provider responses and their cost once' do
    account = create(:account)
    time = Time.utc(2026, 10, 11, 12, 30)
    create(:llm_event, account: account, created_at: time, duration_ms: 200, estimated_cost: 0.002)
    create(:llm_event, account: account, created_at: time, event_name: 'llm.chat.request', duration_ms: 1000,
                       error: true, total_tokens: nil, estimated_cost: nil, payload: { usage_scope: 'outer_request' })
    9.times do
      create(:llm_event, account: account, created_at: time, duration_ms: 100, estimated_cost: 0.001,
                         payload: { usage_scope: 'provider_response' })
    end

    series = described_class.new(scope: LlmEvent.for_account(account.id), date_range: time.beginning_of_hour..time.end_of_hour,
                                 timezone: 'UTC').call

    expect(series[:points].size).to eq(1)
    expect(series[:points].sole).to include(request_count: 10, error_count: 1, avg_duration_ms: 600.0, estimated_cost: 0.011)
  end
end
