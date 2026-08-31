require 'rails_helper'

RSpec.describe Integrations::Medelement::RequestRateLimiter do
  let(:sleeps) { [] }
  let(:connection_pool) { instance_double(ConnectionPool) }
  let(:connection) { instance_double(Redis::Namespace, redis: Object.new) }

  before do
    allow(connection_pool).to receive(:with).and_yield(connection)
  end

  it 'reserves a distributed request slot and sleeps for the returned delay' do
    expected_key = format(
      described_class::KEY_TEMPLATE,
      fingerprint: Digest::SHA256.hexdigest('provider-secret').first(32)
    )
    expect(connection).to receive(:call_with_namespace) do |command, script, keys:, argv:|
      expect(command).to eq(:eval)
      expect(script).to eq(described_class::RESERVE_SCRIPT)
      expect(keys).to eq([expected_key])
      expect(keys.first).not_to include('provider-secret')
      expect(argv).to eq([275])
      425
    end

    described_class.new(
      integrator_key: 'provider-secret',
      interval_ms: 275,
      sleeper: ->(seconds) { sleeps << seconds },
      connection_pool: connection_pool
    ).wait!

    expect(sleeps).to eq([0.425])
  end

  it 'does not touch Redis or sleep when pacing is disabled' do
    expect(connection_pool).not_to receive(:with)

    described_class.new(
      integrator_key: 'provider-secret',
      interval_ms: 0,
      sleeper: ->(seconds) { sleeps << seconds },
      connection_pool: connection_pool
    ).wait!

    expect(sleeps).to be_empty
  end

  it 'normalizes a Redis connection failure without exposing the integrator key' do
    allow(connection_pool).to receive(:with).and_raise(Redis::CannotConnectError, 'provider-secret unavailable')

    expect do
      described_class.new(
        integrator_key: 'provider-secret',
        interval_ms: 275,
        connection_pool: connection_pool
      ).wait!
    end.to raise_error(described_class::UnavailableError) { |error| expect(error.message).not_to include('provider-secret') }
  end

  it 'serializes reservations from separate limiter instances sharing the same key' do
    redis = MockRedis.new
    namespace = Redis::Namespace.new(:medelement_rate_limiter_spec, redis: redis)
    pool = ConnectionPool.new(size: 1, timeout: 1) { namespace }
    clock = -> { Time.zone.at(1_700_000_000) }
    limiter_options = {
      integrator_key: 'provider-secret',
      interval_ms: 275,
      sleeper: ->(seconds) { sleeps << seconds },
      connection_pool: pool,
      clock: clock
    }

    described_class.new(**limiter_options).wait!
    described_class.new(**limiter_options).wait!
    described_class.new(**limiter_options).wait!

    expect(sleeps).to eq([0.275, 0.55])
  end
end
