require 'rails_helper'

RSpec.describe Integrations::Medelement::ReceptionsDeltaJob do
  let(:account) { create(:account).tap { |record| record.enable_features!('scheduling') } }
  let(:hook) { create(:integrations_hook, :medelement, account: account) }
  let(:delta_lock) { instance_double(Redis::LockManager, lock: true, unlock: true, renew: true) }
  let(:full_lock) { instance_double(Redis::LockManager, lock: true, unlock: true, renew: true) }
  let(:poller) { instance_double(Integrations::Medelement::ReceptionsDeltaService, perform: true) }

  before do
    hook.update!(settings: hook.settings.merge('incremental_receptions_enabled' => true))
    allow(Redis::LockManager).to receive(:new).and_return(delta_lock, full_lock)
    allow(Integrations::Medelement::ReceptionsDeltaService).to receive(:new).and_return(poller)
  end

  it 'holds both the delta and full sync locks while polling' do
    described_class.perform_now(hook.id)

    expect(delta_lock).to have_received(:lock).with("MEDELEMENT_RECEPTIONS_DELTA_MUTEX::#{hook.id}", 30.minutes)
    expect(full_lock).to have_received(:lock).with(
      format(Redis::Alfred::MEDELEMENT_SYNC_MUTEX, account_id: account.id), 30.minutes
    )
    expect(poller).to have_received(:perform).once
    expect(delta_lock).to have_received(:unlock).once
    expect(full_lock).to have_received(:unlock).once
  end

  it 'does not start a second poll when the per-hook lock is held' do
    allow(delta_lock).to receive(:lock).and_return(false)

    described_class.perform_now(hook.id)

    expect(poller).not_to have_received(:perform)
    expect(full_lock).not_to have_received(:lock)
  end

  it 'backs off on rate limiting and restores the interval after a successful poll' do
    allow(poller).to receive(:perform).and_raise(
      Integrations::Medelement::Client::ApiError.new('rate limited', status: 429)
    )
    described_class.perform_now(hook.id)
    cursor = Integrations::Medelement::SyncCursor.find_by!(hook: hook)
    expect(cursor.current_interval_seconds).to eq(120)

    cursor.update!(last_poll_at: 3.minutes.ago)
    allow(poller).to receive(:perform) do
      cursor.update!(current_interval_seconds: 60, last_poll_at: Time.current)
    end
    described_class.perform_now(hook.id)
    expect(cursor.reload.current_interval_seconds).to eq(60)
  end

  it 'pauses for five minutes while the full sync lock is held' do
    allow(full_lock).to receive(:lock).and_return(false)

    described_class.perform_now(hook.id)

    expect(poller).not_to have_received(:perform)
    expect(Integrations::Medelement::SyncCursor.find_by!(hook: hook).current_interval_seconds).to eq(300)
  end

  it 'preserves an existing cursor while the full sync lock is held' do
    value = 10.minutes.ago
    cursor = Integrations::Medelement::SyncCursor.create!(hook: hook, name: 'receptions_delta', value: value)
    allow(full_lock).to receive(:lock).and_return(false)

    described_class.perform_now(hook.id)

    expect(cursor.reload.value).to be_within(1.second).of(value)
    expect(cursor.current_interval_seconds).to eq(300)
  end

  it 'caps repeated retryable failures at five minutes' do
    allow(poller).to receive(:perform).and_raise(
      Integrations::Medelement::Client::ApiError.new('server failure', status: 503)
    )

    4.times do
      cursor = Integrations::Medelement::SyncCursor.find_by(hook: hook)
      cursor&.update!(last_poll_at: 6.minutes.ago)
      described_class.perform_now(hook.id)
    end

    expect(Integrations::Medelement::SyncCursor.find_by!(hook: hook).current_interval_seconds).to eq(300)
  end
end
