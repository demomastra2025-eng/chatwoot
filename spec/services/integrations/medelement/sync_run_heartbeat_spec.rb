require 'rails_helper'

RSpec.describe Integrations::Medelement::SyncRunHeartbeat do
  let(:sync_run) { instance_double(Integrations::Medelement::SyncRun) }

  it 'heartbeats until the protected work finishes and stops its thread' do
    heartbeat = Queue.new
    renew_lock = instance_double(Proc, call: true)
    allow(sync_run).to receive(:heartbeat!) { heartbeat << true }
    service = described_class.new(sync_run, interval: 0.01, renew_lock: renew_lock)

    service.around do
      Timeout.timeout(1) { heartbeat.pop }
    end

    expect(sync_run).to have_received(:heartbeat!).at_least(:once)
    expect(renew_lock).to have_received(:call).at_least(:once)
    expect(service.send(:heartbeat_thread)).not_to be_alive
  end

  it 'stops its thread when protected work raises' do
    service = described_class.new(sync_run, interval: 1)

    expect do
      service.around { raise 'provider failed' }
    end.to raise_error(RuntimeError, 'provider failed')

    expect(service.send(:heartbeat_thread)).not_to be_alive
  end

  it 'interrupts protected work when the owner lock lease is lost' do
    renew_lock = instance_double(Proc, call: false)
    allow(sync_run).to receive(:heartbeat!)
    service = described_class.new(sync_run, interval: 0.01, renew_lock: renew_lock)

    expect do
      service.around { sleep 1 }
    end.to raise_error(described_class::LockLeaseLostError, 'Medelement sync lock lease was lost')

    expect(sync_run).not_to have_received(:heartbeat!)
    expect(service.send(:heartbeat_thread)).not_to be_alive
  end

  it 'does not miss an immediate stop before its thread starts waiting' do
    service = described_class.new(sync_run, interval: 60)

    Timeout.timeout(1) { service.around { :done } }

    expect(service.send(:heartbeat_thread)).not_to be_alive
  end
end
