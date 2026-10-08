# frozen_string_literal: true

require 'rails_helper'
require 'fileutils'
require 'tmpdir'

RSpec.describe Storage::RecordingPaths, 'immutable release storage' do
  let(:account) { create(:account) }
  let(:other_account) { create(:account) }
  let(:fixture_root) { Pathname.new(Dir.mktmpdir('recording-release-')).realpath }
  let(:release_root) { fixture_root.join('release') }
  let(:shared_storage) { fixture_root.join('source', 'storage') }
  let(:configured_storage) { release_root.join('storage') }
  let(:key) { "voice-recordings/fixture/#{account.id}/call.wav" }

  before do
    account
    other_account
    FileUtils.mkdir_p(release_root)
    FileUtils.mkdir_p(shared_storage.join(key).dirname)
    File.write(shared_storage.join(key), 'r' * 64)
    File.symlink(shared_storage, configured_storage)
    allow(Rails).to receive(:root).and_return(release_root)
    described_class.configure_root_aliases!
  rescue NotImplementedError, Errno::EPERM
    skip 'Symlinks are not supported by this environment'
  end

  after do
    allow(Rails).to receive(:root).and_call_original
    described_class.configure_root_aliases!
    %w[storage_overview_v1 storage_heavy_recordings_v1 storage_overview_pending_v2 storage_generation_v1 recording_reconciliation_v1].each do |name|
      Redis::Alfred.delete("account:#{account.id}:#{name}")
    end
    Redis::Alfred.delete(account.local_recordings_last_good_cache_key)
    FileUtils.remove_entry(fixture_root) if fixture_root.exist?
  end

  it 'publishes cold physical usage and reads both configured and canonical absolute refs without HTTP filesystem resolution' do
    references = [key, configured_storage.join(key).to_s, shared_storage.join(key).to_s]
    sessions = references.each_with_index.map do |reference, index|
      metadata = index.zero? ? { 'recording' => { 'byte_size' => 64 } } : {}
      create(:telephony_call_session, account: account, recording_ref: reference, metadata: metadata)
    end
    overview = Accounts::StorageOverviewService.new(account: account)

    expect(configured_storage.symlink?).to be(true)
    expect(described_class.root).to eq(shared_storage)
    expect(described_class.resolve(shared_storage.join(key), account_id: account.id)).to eq(shared_storage.join(key))
    expect(overview.refresh![:recording_total_bytes]).to eq(64)
    expect(overview.snapshot[:breakdown][:recordings]).to eq(64)
    expect(sessions.map { |session| Storage::RecordingMetadata.primary_size(session.reload) }).to eq([64, 64, 64])
    expect(described_class).not_to receive(:each_file_with_stat_for_account)
    expect(described_class).not_to receive(:resolve)
    filesystem_resolutions = []
    allow(File).to(receive(:realpath).and_wrap_original do |method, *arguments|
      filesystem_resolutions << arguments.first if arguments.first.to_s.start_with?(fixture_root.to_s)
      method.call(*arguments)
    end)

    files = Accounts::HeavyFilesService.new(account: account, params: { file_type: 'recordings' }).perform

    expect(files.pluck(:id)).to match_array(sessions.map { |session| "call_#{session.id}" })
    expect(files.pluck(:byte_size)).to eq([64, 64, 64])
    expect(filesystem_resolutions).to be_empty
  end

  it 'refreshes again after the daily physical reconciliation expires under the deployment link' do
    overview = Accounts::StorageOverviewService.new(account: account)
    expect(overview.refresh![:recording_total_bytes]).to eq(64)
    File.write(shared_storage.join(key), 'r' * 80)

    travel_to 25.hours.from_now do
      expect(overview.refresh![:recording_total_bytes]).to eq(80)
      expect(overview.snapshot[:recording_total_bytes]).to eq(80)
    end
  end

  it 'rejects nested, leaf and tenant-directory links despite trusting the configured deployment root' do
    own_directory = shared_storage.join(key).dirname
    foreign_directory = shared_storage.join('voice-recordings', 'fixture', other_account.id.to_s)
    FileUtils.mkdir_p(foreign_directory)
    foreign_file = foreign_directory.join('foreign.wav')
    File.write(foreign_file, 'f' * 1000)
    File.symlink(foreign_directory, own_directory.join('redirect'))
    File.symlink(foreign_file, own_directory.join('leaf.wav'))
    linked_tenant = shared_storage.join('voice-recordings', 'linked', account.id.to_s)
    FileUtils.mkdir_p(linked_tenant.dirname)
    File.symlink(foreign_directory, linked_tenant)
    trash_parent = shared_storage.join('trash', account.id.to_s)
    FileUtils.mkdir_p(trash_parent.dirname)
    File.symlink(foreign_directory, trash_parent)

    paths = described_class.each_file_with_stat_for_account(account.id).map { |path, _stat| path }

    expect(paths).to eq([shared_storage.join(key)])
    expect(described_class.resolve("voice-recordings/fixture/#{account.id}/redirect/foreign.wav", account_id: account.id)).to be_nil
    expect(described_class.resolve("voice-recordings/fixture/#{account.id}/leaf.wav", account_id: account.id)).to be_nil
    expect(described_class.resolve("voice-recordings/linked/#{account.id}/foreign.wav", account_id: account.id)).to be_nil
    expect(described_class.within_account?(own_directory.join('redirect', 'restore.wav'), account_id: account.id)).to be(false)
    expect { described_class.prepare_trash_directory(account.id) }.to raise_error(ArgumentError)
    expect(Accounts::StorageOverviewService.new(account: account).refresh![:recording_total_bytes]).to eq(64)
  end

  it 'preserves the last snapshot when the configured deployment link loses its target' do
    overview = Accounts::StorageOverviewService.new(account: account)
    previous = overview.refresh!
    Redis::Alfred.delete("account:#{account.id}:recording_reconciliation_v1")
    FileUtils.remove_entry(shared_storage)

    expect { overview.refresh! }.to raise_error(IOError, 'Unsafe recording storage root')
    expect(overview.snapshot).to eq(previous)
  end
end
