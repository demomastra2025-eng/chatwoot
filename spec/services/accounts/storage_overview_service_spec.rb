# frozen_string_literal: true

require 'rails_helper'
require 'fileutils'

RSpec.describe Accounts::StorageOverviewService do
  include_context 'with isolated recording storage'

  let(:account) { create(:account) }
  let(:service) { described_class.new(account: account) }
  let(:storage_test_cache) { ActiveSupport::Cache::MemoryStore.new }

  before do
    allow(Rails).to receive(:cache).and_return(storage_test_cache)
    Redis::Alfred.delete("account:#{account.id}:storage_overview_v1")
    Redis::Alfred.delete("account:#{account.id}:storage_overview_refresh_v1")
    Redis::Alfred.delete("account:#{account.id}:storage_overview_pending_v2")
    Redis::Alfred.delete("account:#{account.id}:storage_generation_v1")
    Redis::Alfred.delete("account:#{account.id}:recording_reconciliation_v1")
    Redis::Alfred.delete("account:#{account.id}:storage_heavy_recordings_v1")
    Redis::Alfred.delete(account.local_recordings_last_good_cache_key)
  end

  after do
    Redis::Alfred.delete("account:#{account.id}:storage_overview_v1")
    Redis::Alfred.delete("account:#{account.id}:storage_overview_refresh_v1")
    Redis::Alfred.delete("account:#{account.id}:storage_overview_pending_v2")
    Redis::Alfred.delete("account:#{account.id}:storage_generation_v1")
    Redis::Alfred.delete("account:#{account.id}:recording_reconciliation_v1")
    Redis::Alfred.delete("account:#{account.id}:storage_heavy_recordings_v1")
    Redis::Alfred.delete(account.local_recordings_last_good_cache_key)
  end

  it 'queues one housekeeping refresh while the renewable five-minute pending lease is active' do
    expect do
      10.times { service.schedule_refresh(force: true) }
    end.to have_enqueued_job(Accounts::StorageBreakdownRefreshJob).with(account.id).once

    expect(Accounts::StorageBreakdownRefreshJob.new.queue_name).to eq('housekeeping')
  end

  it 'recovers from an orphan pending marker after five minutes' do
    service.schedule_refresh(force: true)

    travel_to 6.minutes.from_now do
      expect { service.schedule_refresh(force: true) }.to have_enqueued_job(Accounts::StorageBreakdownRefreshJob).with(account.id)
    end
    expect(described_class::PENDING_REFRESH_TTL).to eq(5.minutes)
  end

  it 'releases the pending marker when the refresh job finishes' do
    pending_key = "account:#{account.id}:storage_overview_pending_v2"
    job = Accounts::StorageBreakdownRefreshJob.new(account.id)
    Redis::Alfred.set(pending_key, job.job_id, ex: 1.hour.to_i)
    allow(described_class).to receive(:new).and_return(service)
    allow(service).to receive(:refresh!).and_return(generation: 0, updated_at: Time.current.to_i)

    job.perform_now

    expect(Redis::Alfred.get(pending_key)).to be_nil
  end

  it 'refreshes the same category, inbox, and quota numbers as the existing calculation' do
    inboxes = create_list(:inbox, 2, account: account)
    [[:image, 'photo.png', 'image/png'], [:file, 'report.pdf', 'application/pdf']].each_with_index do |(type, name, content_type), index|
      message = create(:message, account: account, inbox: inboxes[index])
      attachment = message.attachments.new(account_id: account.id, file_type: type)
      attachment.file.attach(io: StringIO.new('fixture' * (index + 1)), filename: name, content_type: content_type)
      attachment.save!
    end
    recording_path = Storage::RecordingPaths.root.join('voice-recordings', 'fixture', account.id.to_s, 'call.wav')
    FileUtils.mkdir_p(recording_path.dirname)
    File.write(recording_path, 'recording fixture')
    create(:telephony_call_session, account: account, inbox: inboxes.first,
                                    recording_ref: "voice-recordings/fixture/#{account.id}/call.wav")

    expected_breakdown = account.calculate_storage_breakdown
    expected_limits = AccountLimits::StorageUsageService.new(account: account).summary
    Accounts::StorageBreakdownRefreshJob.perform_now(account.id)
    snapshot = service.snapshot

    expect(snapshot[:breakdown].except(:last_updated_at, :recordings_reconciled_at))
      .to eq(expected_breakdown.except(:last_updated_at, :recordings_reconciled_at))
    expect(snapshot[:limits]).to eq(expected_limits)
    expect(snapshot[:breakdown][:recordings]).to eq(File.size(recording_path))
    recording = Accounts::HeavyRecordingsSnapshot.new(account_id: account.id).snapshot[:recordings].sole
    expect(recording).to include(byte_size: File.size(recording_path), inbox_id: inboxes.first.id)
    expect(recording[:id]).to start_with('call_')
    expect(service.snapshot).to eq(snapshot)
  end

  it 'limits the aggregate queries with a session timeout and puts the previous one back' do
    statements = []
    subscriber = ->(*, payload) { statements << payload[:sql] }
    timeout_before = ActiveRecord::Base.connection.select_value('SHOW statement_timeout')

    ActiveSupport::Notifications.subscribed(subscriber, 'sql.active_record') { service.refresh! }

    expect(statements).to include("SET statement_timeout = '10s'")
    expect(ActiveRecord::Base.connection.select_value('SHOW statement_timeout')).to eq(timeout_before)
  end

  it 'puts the previous timeout back when the calculation fails' do
    timeout_before = ActiveRecord::Base.connection.select_value('SHOW statement_timeout')
    allow(account).to receive(:storage_breakdown).with(force_refresh: true, heavy_recordings: anything, recording_usage: anything)
                                                 .and_raise(ActiveRecord::StatementInvalid, 'statement timeout')

    expect { service.refresh! }.to raise_error(ActiveRecord::StatementInvalid)
    expect(ActiveRecord::Base.connection.select_value('SHOW statement_timeout')).to eq(timeout_before)
  end

  # The production server drops connections idle in a transaction after one minute; the calculation walks the
  # recordings on disk for minutes, so it must not run inside a transaction of its own.
  it 'does not open a database transaction around the breakdown calculation' do
    baseline = ActiveRecord::Base.connection.open_transactions
    seen = nil
    allow(account).to receive(:storage_breakdown).with(force_refresh: true, heavy_recordings: anything, recording_usage: anything) do
      seen = ActiveRecord::Base.connection.open_transactions
      {}
    end

    service.refresh!

    expect(seen).to eq(baseline)
  end

  it 'keeps the last good snapshot when an aggregate times out' do
    previous = service.refresh!
    previous_recordings = Accounts::HeavyRecordingsSnapshot.new(account_id: account.id).snapshot
    allow(account).to receive(:storage_breakdown).with(force_refresh: true, heavy_recordings: anything, recording_usage: anything)
                                                 .and_raise(ActiveRecord::StatementInvalid, 'statement timeout')

    expect { service.refresh! }.to raise_error(ActiveRecord::StatementInvalid)
    expect(service.snapshot).to eq(previous)
    expect(Accounts::HeavyRecordingsSnapshot.new(account_id: account.id).snapshot).to eq(previous_recordings)
  end

  it 'handles a timed-out refresh job without replacing the last good snapshot' do
    previous = service.refresh!
    allow(described_class).to receive(:new).and_return(service)
    allow(service).to receive(:refresh!).and_raise(ActiveRecord::StatementInvalid, 'statement timeout')

    expect { Accounts::StorageBreakdownRefreshJob.perform_now(account.id) }.not_to raise_error
    expect(service.snapshot).to eq(previous)
  end

  it 'reports queued, already pending and failed enqueue states accurately' do
    service.schedule_refresh(force: true)
    expect(service.refresh_status).to eq('queued')
    service.schedule_refresh(force: true)
    expect(service.refresh_status).to eq('pending')
    Redis::Alfred.delete("account:#{account.id}:storage_overview_pending_v2")
    job = Accounts::StorageBreakdownRefreshJob.new(account.id)
    allow(Accounts::StorageBreakdownRefreshJob).to receive(:new).and_return(job)
    allow(job).to receive(:enqueue).and_raise(StandardError, 'queue unavailable')

    service.schedule_refresh(force: true)

    expect(service.refresh_status).to eq('failed')
    expect(service.pending?).to be(false)
  end

  it 'cannot publish a pre-mutation calculation and schedules a successor when the claimed job finishes' do
    previous = service.refresh!
    allow(described_class).to receive(:new).and_return(service)
    allow(account).to receive(:storage_breakdown).and_wrap_original do |method, **arguments|
      service.invalidate!
      method.call(**arguments)
    end

    expect { Accounts::StorageBreakdownRefreshJob.perform_now(account.id) }
      .to have_enqueued_job(Accounts::StorageBreakdownRefreshJob).with(account.id).once

    expect(service.snapshot).to eq(previous)
    expect(service.stale?(service.snapshot)).to be(true)
  end

  it 'does not release another worker lease or publish after losing its own lease' do
    previous = service.refresh!
    pending_key = "account:#{account.id}:storage_overview_pending_v2"
    Redis::Alfred.set(pending_key, 'new-worker', ex: 5.minutes.to_i)

    expect(service.refresh!(job_id: 'expired-worker')).to be_nil
    described_class.release_refresh(account.id, 'expired-worker')

    expect(Redis::Alfred.get(pending_key)).to eq('new-worker')
    expect(service.snapshot).to eq(previous)
  end

  it 'renews its lease during background reconciliation without a long database transaction' do
    pending_key = "account:#{account.id}:storage_overview_pending_v2"
    Redis::Alfred.set(pending_key, 'worker', ex: 5.minutes.to_i)
    allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC).and_return(0, 31)
    heartbeat = service.send(:lease_heartbeat, 'worker')
    expect(Redis::Alfred).to receive(:expire_if_value).with(pending_key, 'worker', 5.minutes.to_i).and_call_original

    heartbeat.call

    expect(Redis::Alfred.get(pending_key)).to eq('worker')
  end

  it 'keeps the last measured physical total when a background filesystem reconciliation fails' do
    path = Storage::RecordingPaths.root.join('voice-recordings', 'fixture', account.id.to_s, 'unlinked.wav')
    FileUtils.mkdir_p(path.dirname)
    File.write(path, 'r' * 50)
    previous = service.refresh!
    Redis::Alfred.delete("account:#{account.id}:recording_reconciliation_v1")
    allow(Storage::RecordingPaths).to receive(:each_file_with_stat_for_account).and_raise(Errno::EIO)

    expect { service.refresh! }.to raise_error(Errno::EIO)

    expect(service.snapshot).to eq(previous)
    expect(account.local_recordings_bytes).to eq(50)
  end

  it 'cannot overwrite newer reconciliation or quota totals when an orphan-only worker resumes after publication' do
    path = Storage::RecordingPaths.root.join('voice-recordings', 'fixture', account.id.to_s, 'orphan.wav')
    FileUtils.mkdir_p(path.dirname)
    File.write(path, 'r' * 10)
    pending_key = "account:#{account.id}:storage_overview_pending_v2"
    reconciliation_key = "account:#{account.id}:recording_reconciliation_v1"
    Redis::Alfred.set(pending_key, 'old-worker', ex: 5.minutes.to_i)
    Rails.cache.write(account.local_recordings_bytes_cache_key, 10)
    Rails.cache.write(account.local_recordings_last_good_cache_key, 10)
    paused = false
    allow(Redis::Alfred).to receive(:publish_storage_snapshot).and_wrap_original do |method, keys, values|
      result = method.call(keys, values)
      unless paused
        paused = true
        expect(JSON.parse(Redis::Alfred.get(reconciliation_key))['unlinked_files'].sum { |file| file['byte_size'] }).to eq(10)
        travel 25.hours
        File.write(path, 'r' * 20)
        Redis::Alfred.set(pending_key, 'new-worker', ex: 5.minutes.to_i)
        described_class.new(account: account).refresh!(job_id: 'new-worker')
      end
      result
    end

    service.refresh!(job_id: 'old-worker')

    expect(service.snapshot[:recording_total_bytes]).to eq(20)
    expect(JSON.parse(Redis::Alfred.get(reconciliation_key))['unlinked_files'].sum { |file| file['byte_size'] }).to eq(20)
    expect(account.local_recordings_bytes).to eq(20)
    expect(Redis::Alfred.get(account.local_recordings_last_good_cache_key)).to eq('20')
    described_class.new(account: account).refresh!(job_id: 'new-worker')
    expect(service.snapshot[:recording_total_bytes]).to eq(20)
  ensure
    travel_back
  end
end
