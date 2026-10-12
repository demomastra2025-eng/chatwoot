require 'rails_helper'

RSpec.describe Integrations::Medelement::RequestRateLimiter do
  let(:sleeps) { [] }
  let(:connection_pool) { instance_double(ConnectionPool) }
  let(:connection) { instance_double(Redis::Namespace, redis: Object.new) }

  before do
    allow(connection_pool).to receive(:with).and_yield(connection)
  end

  def lane_key(login:, operation:)
    format(
      described_class::KEY_TEMPLATE,
      fingerprint: Digest::SHA256.hexdigest("provider-secret\n#{login}").first(32),
      operation: operation
    )
  end

  it 'reserves a distributed slot of the request type and sleeps for the returned delay' do
    expect(connection).to receive(:call_with_namespace) do |command, script, keys:, argv:|
      expect(command).to eq(:eval)
      expect(script).to eq(described_class::RESERVE_SCRIPT)
      expect(keys).to eq([lane_key(login: 'clinic-1', operation: 'reception_create')])
      expect(keys.first).not_to include('provider-secret')
      expect(keys.first).not_to include('clinic-1')
      expect(argv).to eq([275, described_class::MAX_INLINE_WAIT_MS])
      425
    end

    described_class.new(
      integrator_key: 'provider-secret',
      account_login: 'clinic-1',
      interval_ms: 275,
      sleeper: ->(seconds) { sleeps << seconds },
      connection_pool: connection_pool
    ).wait!(operation: 'reception create')

    expect(sleeps).to eq([0.425])
  end

  it 'allows a write to wait longer for its slot than a read' do
    expect(connection).to receive(:call_with_namespace) do |_command, _script, keys:, argv:|
      expect(keys).to eq([lane_key(login: 'clinic-1', operation: 'reception_move')])
      expect(argv).to eq([200, described_class::MAX_INLINE_WRITE_WAIT_MS])
      0
    end

    described_class.new(
      integrator_key: 'provider-secret', account_login: 'clinic-1', interval_ms: 200, connection_pool: connection_pool
    ).wait!(operation: 'reception move', write: true)
  end

  [0, 50, 199, -10].each do |too_short|
    it "never spaces requests closer than the provider allows, whatever interval #{too_short} asks for" do
      expect(connection).to receive(:call_with_namespace) do |_command, _script, keys:, argv:|
        expect(keys).to eq([lane_key(login: '', operation: 'timetable')])
        expect(argv).to eq([200, described_class::MAX_INLINE_WAIT_MS])
        200
      end

      described_class.new(
        integrator_key: 'provider-secret',
        interval_ms: too_short,
        sleeper: ->(seconds) { sleeps << seconds },
        connection_pool: connection_pool
      ).wait!(operation: 'timetable')

      expect(sleeps).to eq([0.2])
    end
  end

  it 'keeps a longer interval that a hook asks for' do
    expect(connection).to receive(:call_with_namespace) do |_command, _script, keys:, argv:|
      expect(keys.size).to eq(1)
      expect(argv).to eq([500, described_class::MAX_INLINE_WAIT_MS])
      0
    end

    described_class.new(integrator_key: 'provider-secret', interval_ms: 500, connection_pool: connection_pool).wait!(operation: 'timetable')
  end

  it 'normalizes a Redis connection failure without exposing the integrator key' do
    allow(connection_pool).to receive(:with).and_raise(Redis::CannotConnectError, 'provider-secret unavailable')

    expect do
      described_class.new(
        integrator_key: 'provider-secret',
        interval_ms: 200,
        connection_pool: connection_pool
      ).wait!(operation: 'timetable')
    end.to raise_error(described_class::UnavailableError) { |error| expect(error.message).not_to include('provider-secret') }
  end

  it 'defaults to the 200 ms spacing that keeps an account within five requests per second' do
    expect(described_class::DEFAULT_INTERVAL_MS).to eq(200)
    expect(Integrations::Medelement::Configuration::DEFAULT_THROTTLE_MS).to eq(200)
  end

  describe 'spacing across processes' do
    let(:redis) { MockRedis.new }
    let(:namespace) { Redis::Namespace.new(:medelement_rate_limiter_spec, redis: redis) }
    let(:pool) { ConnectionPool.new(size: 1, timeout: 1) { namespace } }
    let(:now) { Time.zone.at(1_700_000_000) }
    let(:clock) { -> { now } }

    def limiter(login: 'clinic-1', interval_ms: 200)
      described_class.new(
        integrator_key: 'provider-secret', account_login: login, interval_ms: interval_ms,
        sleeper: ->(seconds) { sleeps << seconds }, connection_pool: pool, clock: clock
      )
    end

    it 'spaces requests of the same type of the same account by the interval, from separate limiter instances' do
      3.times { limiter.wait!(operation: 'reception create') }

      expect(sleeps).to eq([0.2, 0.4])
    end

    it 'does not make one request type wait for another' do
      limiter.wait!(operation: 'reception create')
      limiter.wait!(operation: 'timetable')
      limiter.wait!(operation: 'receptions')
      limiter.wait!(operation: 'reception create')

      expect(sleeps).to eq([0.2])
    end

    it 'does not make one account wait for another' do
      limiter(login: 'clinic-1').wait!(operation: 'timetable')
      limiter(login: 'clinic-2').wait!(operation: 'timetable')

      expect(sleeps).to be_empty
    end

    it 'lets the next request through once the interval has passed' do
      limiter.wait!(operation: 'timetable')
      later = now + 0.2.seconds
      allow(clock).to receive(:call).and_return(later)

      limiter.wait!(operation: 'timetable')

      expect(sleeps).to be_empty
    end

    it 'treats the request type as the endpoint operation whatever its spelling' do
      limiter.wait!(operation: 'Reception Create')
      limiter.wait!(operation: 'reception-create')

      expect(sleeps).to eq([0.2])
    end

    it 'refuses to sleep past the cap and reserves nothing for the refused caller' do
      ((described_class::MAX_INLINE_WAIT_MS / 200) + 1).times { limiter.wait!(operation: 'receptions') }
      sleeps.clear

      retry_after = []
      2.times do
        expect { limiter.wait!(operation: 'receptions') }.to raise_error(described_class::BusyError) do |error|
          expect(error.operation).to eq('receptions')
          retry_after << error.retry_after_ms
        end
      end

      expect(retry_after.first).to be > described_class::MAX_INLINE_WAIT_MS
      expect(retry_after.uniq).to eq([retry_after.first])
      expect(sleeps).to be_empty
    end

    it 'tells whether the refused request was a write' do
      ((described_class::MAX_INLINE_WRITE_WAIT_MS / 200) + 1).times { limiter.wait!(operation: 'reception create', write: true) }

      expect { limiter.wait!(operation: 'reception create', write: true) }.to raise_error(described_class::BusyError) do |error|
        expect(error).to be_write
      end
      expect { limiter.wait!(operation: 'reception create') }.to raise_error(described_class::BusyError) do |error|
        expect(error).not_to be_write
      end
    end

    it 'lets a write queue behind more requests than a read before it is refused' do
      ((described_class::MAX_INLINE_WAIT_MS / 200) + 5).times { limiter.wait!(operation: 'reception move', write: true) }

      expect { limiter.wait!(operation: 'reception move') }.to raise_error(described_class::BusyError)
      expect { limiter.wait!(operation: 'reception move', write: true) }.not_to raise_error
    end
  end
end
