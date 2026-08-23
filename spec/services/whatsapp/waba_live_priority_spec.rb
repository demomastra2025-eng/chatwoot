require 'rails_helper'

RSpec.describe Whatsapp::WabaLivePriority do
  let(:waba_id) { "waba-live-priority-#{SecureRandom.hex(8)}" }

  it 'marks live demand only while the guarded work is active' do
    expect(described_class.waiting?(waba_id)).to be(false)

    described_class.with_waiters([waba_id], waiter_id: 'job-1') do
      expect(described_class.waiting?(waba_id)).to be(true)
    end

    expect(described_class.waiting?(waba_id)).to be(false)
  end

  it 'does not clear another live waiter for the same WABA' do
    described_class.with_waiters([waba_id], waiter_id: 'job-1') do
      described_class.with_waiters([waba_id], waiter_id: 'job-2') do
        expect(described_class.waiting?(waba_id)).to be(true)
      end

      expect(described_class.waiting?(waba_id)).to be(true)
    end
  end

  it 'cleans up its waiter when live dispatch raises' do
    expect do
      described_class.with_waiters([waba_id], waiter_id: 'job-1') { raise 'dispatch failed' }
    end.to raise_error('dispatch failed')

    expect(described_class.waiting?(waba_id)).to be(false)
  end

  it 'keeps a stable waiter registered while the live job retries WABA lock contention' do
    expect do
      described_class.with_waiters([waba_id], waiter_id: 'stable-job') do
        raise Whatsapp::WabaLock::LockAcquisitionError
      end
    end.to raise_error(Whatsapp::WabaLock::LockAcquisitionError)
    expect(described_class.waiting?(waba_id)).to be(true)

    described_class.with_waiters([waba_id], waiter_id: 'stable-job') { :completed }

    expect(described_class.waiting?(waba_id)).to be(false)
  end

  it 'prunes a waiter left behind by a crashed process' do
    waiter = described_class.new(waba_id)
    waiter.register!

    travel(described_class::WAITER_TTL + 1.second) do
      expect(described_class.waiting?(waba_id)).to be(false)
    end
  ensure
    waiter&.release!
  end

  it 'raises when history work checks while live traffic is waiting' do
    described_class.with_waiters([waba_id], waiter_id: 'job-1') do
      expect { described_class.ensure_clear!(waba_id) }
        .to raise_error(Whatsapp::WabaLivePriority::LiveTrafficPendingError)
    end
  end
end
