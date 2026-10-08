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
    Redis::Alfred.delete("account:#{account.id}:storage_overview_pending_v1")
    Redis::Alfred.delete("account:#{account.id}:storage_heavy_recordings_v1")
  end

  after do
    Redis::Alfred.delete("account:#{account.id}:storage_overview_v1")
    Redis::Alfred.delete("account:#{account.id}:storage_overview_refresh_v1")
    Redis::Alfred.delete("account:#{account.id}:storage_overview_pending_v1")
    Redis::Alfred.delete("account:#{account.id}:storage_heavy_recordings_v1")
  end

  it 'queues one housekeeping refresh while the five-minute lease is active' do
    expect do
      10.times { service.schedule_refresh(force: true) }
    end.to have_enqueued_job(Accounts::StorageBreakdownRefreshJob).with(account.id).once

    expect(Accounts::StorageBreakdownRefreshJob.new.queue_name).to eq('housekeeping')
  end

  it 'does not queue another refresh after the five-minute lease expires while the first job is pending' do
    service.schedule_refresh(force: true)
    Redis::Alfred.delete("account:#{account.id}:storage_overview_refresh_v1")

    expect { service.schedule_refresh(force: true) }.not_to have_enqueued_job(Accounts::StorageBreakdownRefreshJob)
  end

  it 'releases the pending marker when the refresh job finishes' do
    pending_key = "account:#{account.id}:storage_overview_pending_v1"
    job = Accounts::StorageBreakdownRefreshJob.new(account.id)
    Redis::Alfred.set(pending_key, job.job_id, ex: 1.hour.to_i)
    allow(described_class).to receive(:new).and_return(service)
    allow(service).to receive(:refresh!)

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

    expect(snapshot[:breakdown].except(:last_updated_at)).to eq(expected_breakdown.except(:last_updated_at))
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
    allow(account).to receive(:storage_breakdown).with(force_refresh: true, heavy_recordings: anything)
                                                 .and_raise(ActiveRecord::StatementInvalid, 'statement timeout')

    expect { service.refresh! }.to raise_error(ActiveRecord::StatementInvalid)
    expect(ActiveRecord::Base.connection.select_value('SHOW statement_timeout')).to eq(timeout_before)
  end

  # The production server drops connections idle in a transaction after one minute; the calculation walks the
  # recordings on disk for minutes, so it must not run inside a transaction of its own.
  it 'does not open a database transaction around the breakdown calculation' do
    baseline = ActiveRecord::Base.connection.open_transactions
    seen = nil
    allow(account).to receive(:storage_breakdown).with(force_refresh: true, heavy_recordings: anything) do
      seen = ActiveRecord::Base.connection.open_transactions
      {}
    end

    service.refresh!

    expect(seen).to eq(baseline)
  end

  it 'keeps the last good snapshot when an aggregate times out' do
    previous = service.refresh!
    previous_recordings = Accounts::HeavyRecordingsSnapshot.new(account_id: account.id).snapshot
    allow(account).to receive(:storage_breakdown).with(force_refresh: true, heavy_recordings: anything)
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
end
