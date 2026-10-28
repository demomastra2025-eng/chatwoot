require 'rails_helper'

RSpec.describe Integrations::Medelement::RequestTelemetry do
  let(:redis) { MockRedis.new }
  let(:pool) { ConnectionPool.new(size: 1, timeout: 1) { Redis::Namespace.new(:medelement_telemetry_spec, redis: redis) } }
  let(:now) { Time.zone.parse('2026-10-28 12:05:00 UTC') }
  let(:configuration) do
    instance_double(Integrations::Medelement::Configuration, account_id: 11, hook_id: 22,
                                                             integrator_key: 'fake-key', company_login: 'fake-clinic')
  end

  it 'counts every HTTP attempt and records a safe 429 hint and first-limit request number' do
    telemetry = described_class.new(configuration: configuration, pool: pool, clock: -> { now })
    success = Struct.new(:code, :headers, :body).new(200, {}, '{}')
    headers = { 'Retry-After' => '30', 'X-RateLimit-Remaining' => '0', 'X-RateLimit-Reason' => 'Alice' }
    rejected = Struct.new(:code, :headers, :body).new(429, headers, 'Too many requests for patient Alice')
    telemetry.record(operation: 'timetable', lane: :sync_far, response: success, duration_ms: 30)
    telemetry.record(operation: 'patient search', lane: :live, response: rejected, duration_ms: 40)

    rows = described_class.report(hours: 1, pool: pool, now: now)
    expect(rows.map { |row| row.values_at(:lane, :status, :count) }).to contain_exactly(
      ['sync_far', '200', 1], ['live', '429', 1]
    )
    expect(rows.last[:first_429_at_count]).to eq(2)
    expect(rows.last[:last_429_hint]).to eq('rate_limit')
    expect(rows.last[:last_429_headers]).to include('retry-after', 'x-ratelimit-remaining')
    expect(rows.last[:last_429_headers]).to include('"x-ratelimit-reason":"[non-numeric]"')
    expect(rows.last.to_s).not_to include('Alice')
  end

  it 'shows a credential-wide 429 count when two hooks share credentials' do
    attributes = { account_id: 33, hook_id: 44, integrator_key: 'fake-key', company_login: 'fake-clinic' }
    other_configuration = instance_double(Integrations::Medelement::Configuration, **attributes)
    first = described_class.new(configuration: configuration, pool: pool, clock: -> { now })
    second = described_class.new(configuration: other_configuration, pool: pool, clock: -> { now })
    response = Struct.new(:code, :headers, :body).new(429, {}, 'Too many requests')
    first.record(operation: 'timetable', lane: :sync_far, response: response, duration_ms: 10)
    second.record(operation: 'receptions', lane: :other_jobs, response: response, duration_ms: 10)

    expect(first.current_hour).to include('total' => 2, 'rate_limited' => 2)
  end
end
