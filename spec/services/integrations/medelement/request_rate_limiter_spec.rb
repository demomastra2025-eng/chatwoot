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

  it 'evaluates budget reservation, two-key global slot reservation, budget rollback, and pause Lua scripts' do
    limiter = described_class.new(
      integrator_key: 'provider-secret', account_login: 'clinic-1', interval_ms: 200,
      global_interval_ms: 125, budget_per_minute: 30, live_reserve_per_minute: 10,
      connection_pool: connection_pool
    )
    expected_global_key = format(
      described_class::GLOBAL_KEY_TEMPLATE,
      fingerprint: Digest::SHA256.hexdigest('provider-secret').first(32)
    )
    expected_budget_key = format(
      described_class::BUDGET_KEY_TEMPLATE,
      fingerprint: Digest::SHA256.hexdigest("provider-secret\nclinic-1").first(32)
    )

    expect(connection).to receive(:call_with_namespace).with(
      :eval, described_class::BUDGET_SCRIPT, keys: [expected_budget_key], argv: ['sync_near', 30, 10, 5]
    ).ordered.and_return(29_889_000)
    expect(connection).to receive(:call_with_namespace).with(
      :eval, described_class::RESERVE_SCRIPT,
      keys: [lane_key(login: 'clinic-1', operation: 'receptions_delta'), expected_global_key],
      argv: [200, described_class::MAX_GLOBAL_WAIT_MS, 125]
    ).ordered.and_return(-12_000)
    expect(connection).to receive(:call_with_namespace).with(
      :eval, described_class::RELEASE_BUDGET_SCRIPT, keys: [expected_budget_key], argv: ['sync_near', 29_889_000]
    ).ordered.and_return(0)

    expect { limiter.wait!(operation: 'receptions_delta', lane: :sync_near) }
      .to raise_error(described_class::BusyError) { |err| expect(err.retry_after_ms).to eq(12_000) }

    expect(connection).to receive(:call_with_namespace).with(
      :eval, described_class::PAUSE_SCRIPT, keys: [expected_budget_key], argv: [0.0005]
    ).ordered.and_return(1)

    expect(limiter.record_429!(retry_after_seconds: 0.0005)).to eq(1)
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

    it 'releases an idle ActiveRecord connection before sleeping when no transaction is open' do
      limiter.wait!(operation: 'reception create')
      allow(ActiveRecord::Base.connection_pool).to receive(:active_connection?).and_return(true)
      allow(ActiveRecord::Base.connection).to receive(:open_transactions).and_return(0)
      expect(ActiveRecord::Base.connection_pool).to receive(:release_connection).once

      limiter.wait!(operation: 'reception create')
    end

    it 'shares one minute budget across operations and keeps a live reserve' do
      limited = described_class.new(
        integrator_key: 'provider-secret', account_login: 'clinic-1', interval_ms: 200,
        budget_per_minute: 3, live_reserve_per_minute: 1, connection_pool: pool, clock: clock,
        sleeper: ->(seconds) { sleeps << seconds }
      )
      limited.wait!(operation: 'timetable', lane: :sync_far)
      limited.wait!(operation: 'receptions', lane: :sync_near)

      expect { limited.wait!(operation: 'patient', lane: :other_jobs) }.to raise_error(described_class::BusyError)
      expect { limited.wait!(operation: 'patient', lane: :live) }.not_to raise_error
      expect { limited.wait!(operation: 'reception create', lane: :live) }.to raise_error(described_class::BusyError)
    end

    it 'pauses background lanes after a provider 429 while live continues' do
      limited = described_class.new(
        integrator_key: 'provider-secret', account_login: 'clinic-1', interval_ms: 200,
        budget_per_minute: 3, live_reserve_per_minute: 1, connection_pool: pool, clock: clock
      )
      limited.record_429!(retry_after_seconds: 30)

      expect { limited.wait!(operation: 'timetable', lane: :sync_far) }.to raise_error(described_class::BusyError) do |error|
        expect(error.retry_after_ms).to be_between(1, 30_000)
        expect(error).to be_paused
      end
      expect { limited.wait!(operation: 'patient', lane: :live) }.not_to raise_error
    end

    it 'keeps a near-sync share available when far sync and other jobs fill their share' do
      limited = described_class.new(
        integrator_key: 'provider-secret', account_login: 'clinic-1', interval_ms: 200,
        budget_per_minute: 6, live_reserve_per_minute: 1, connection_pool: pool, clock: clock
      )
      4.times { limited.wait!(operation: 'timetable', lane: :sync_far) }

      expect { limited.wait!(operation: 'receptions', lane: :other_jobs) }.to raise_error(described_class::BusyError)
      expect { limited.wait!(operation: 'timetable', lane: :sync_near) }.not_to raise_error
      expect { limited.wait!(operation: 'patient', lane: :live) }.not_to raise_error
    end

    it 'debounces concurrent headerless 429 bursts without escalating pause to five minutes' do
      limited = described_class.new(
        integrator_key: 'provider-secret', account_login: 'clinic-1', interval_ms: 200,
        budget_per_minute: 10, live_reserve_per_minute: 2, connection_pool: pool, clock: clock
      )

      pauses = Array.new(6) { limited.record_429! }
      expect(pauses.first).to eq(5_000)
      expect(pauses.max).to be <= 5_000
    end

    it 'paces background traffic across clinics sharing an integrator key while letting live traffic bypass global wait' do
      clinic_a = described_class.new(
        integrator_key: 'shared-integrator', account_login: 'clinic-a', interval_ms: 200,
        global_interval_ms: 125, budget_per_minute: 10, live_reserve_per_minute: 2,
        connection_pool: pool, clock: clock, sleeper: ->(seconds) { sleeps << [:a, seconds] }
      )
      clinic_b = described_class.new(
        integrator_key: 'shared-integrator', account_login: 'clinic-b', interval_ms: 200,
        global_interval_ms: 125, budget_per_minute: 10, live_reserve_per_minute: 2,
        connection_pool: pool, clock: clock, sleeper: ->(seconds) { sleeps << [:b, seconds] }
      )

      clinic_a.wait!(operation: 'receptions_delta', lane: :sync_near)
      clinic_b.wait!(operation: 'receptions_delta', lane: :sync_near)
      clinic_b.wait!(operation: 'patient', lane: :live)

      expect(sleeps).to eq([[:b, 0.125]])
    end

    it 'does not consume a global integrator slot when the calling clinic is paused' do
      paused_clinic = described_class.new(
        integrator_key: 'shared-integrator', account_login: 'clinic-paused', interval_ms: 200,
        global_interval_ms: 125, budget_per_minute: 10, live_reserve_per_minute: 2,
        connection_pool: pool, clock: clock, sleeper: ->(seconds) { sleeps << [:paused, seconds] }
      )
      healthy_clinic = described_class.new(
        integrator_key: 'shared-integrator', account_login: 'clinic-healthy', interval_ms: 200,
        global_interval_ms: 125, budget_per_minute: 10, live_reserve_per_minute: 2,
        connection_pool: pool, clock: clock, sleeper: ->(seconds) { sleeps << [:healthy, seconds] }
      )
      paused_clinic.record_429!(retry_after_seconds: 15)

      expect { paused_clinic.wait!(operation: 'receptions', lane: :sync_far) }.to raise_error(described_class::BusyError)
      healthy_clinic.wait!(operation: 'receptions', lane: :sync_far)

      expect(sleeps).to be_empty
    end

    it 'clamps sub-millisecond Retry-After pauses to at least 1 ms without raising a Redis error' do
      limited = described_class.new(
        integrator_key: 'provider-secret', account_login: 'clinic-1', interval_ms: 200,
        budget_per_minute: 10, live_reserve_per_minute: 2, connection_pool: pool, clock: clock
      )

      expect(limited.record_429!(retry_after_seconds: 0.0004)).to eq(1)
    end

    it 'exempts write requests from background global pacing and background pauses even on default lanes' do
      clinic_a = described_class.new(
        integrator_key: 'shared-integrator', account_login: 'clinic-a', interval_ms: 200,
        global_interval_ms: 125, budget_per_minute: 3, live_reserve_per_minute: 1,
        connection_pool: pool, clock: clock, sleeper: ->(seconds) { sleeps << [:a, seconds] }
      )
      clinic_b = described_class.new(
        integrator_key: 'shared-integrator', account_login: 'clinic-b', interval_ms: 200,
        global_interval_ms: 125, budget_per_minute: 3, live_reserve_per_minute: 1,
        connection_pool: pool, clock: clock, sleeper: ->(seconds) { sleeps << [:b, seconds] }
      )
      clinic_a.wait!(operation: 'receptions_delta', lane: :sync_near)
      clinic_b.wait!(operation: 'timetable', lane: :sync_far)
      clinic_b.wait!(operation: 'receptions', lane: :sync_near)
      clinic_b.record_429!(retry_after_seconds: 30)
      sleeps.clear

      clinic_b.wait!(operation: 'patient update', write: true, lane: :other_jobs)

      expect(sleeps).to be_empty
    end

    it 'refunds the reserved minute budget on slot refusal across minute zero and minute rollovers' do
      epoch_time = Time.zone.at(10)
      epoch_limiter = described_class.new(
        integrator_key: 'provider-secret', account_login: 'clinic-zero', interval_ms: 200,
        budget_per_minute: 3, live_reserve_per_minute: 1, connection_pool: pool, clock: -> { epoch_time }
      )
      allow(epoch_limiter).to receive(:reserve_delay_ms).and_return(-5_000, 0)

      expect { epoch_limiter.wait!(operation: 'receptions', lane: :sync_far) }.to raise_error(described_class::BusyError)
      expect { epoch_limiter.wait!(operation: 'timetable', lane: :sync_far) }.not_to raise_error

      times = [Time.zone.at(119), Time.zone.at(120)]
      rollover_clock = -> { times.shift || Time.zone.at(120) }
      rollover_limiter = described_class.new(
        integrator_key: 'provider-secret', account_login: 'clinic-rollover', interval_ms: 200,
        budget_per_minute: 3, live_reserve_per_minute: 1, connection_pool: pool, clock: rollover_clock
      )
      allow(rollover_limiter).to receive(:reserve_delay_ms).and_return(-5_000)

      expect { rollover_limiter.wait!(operation: 'receptions', lane: :sync_far) }.to raise_error(described_class::BusyError)

      same_minute_limiter = described_class.new(
        integrator_key: 'provider-secret', account_login: 'clinic-rollover', interval_ms: 200,
        budget_per_minute: 3, live_reserve_per_minute: 1, connection_pool: pool, clock: -> { Time.zone.at(119) }
      )
      expect { same_minute_limiter.wait!(operation: 'timetable', lane: :sync_far) }.not_to raise_error
    end
  end
end
