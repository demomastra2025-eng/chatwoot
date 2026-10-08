# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Storage::RecordingInventory do
  include_context 'with isolated recording storage'

  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:number_binding) { create(:telephony_number_binding, account: account, inbox: inbox) }
  let(:cache) { ActiveSupport::Cache::MemoryStore.new }

  before { allow(Rails).to receive(:cache).and_return(cache) }
  after { Redis::Alfred.delete("account:#{account.id}:recording_reconciliation_v1") }

  def recording_file(name, bytes, tenant: account.id, trash: false)
    key = trash ? "trash/#{tenant}/recordings/#{name}" : "voice-recordings/fixture/#{tenant}/#{name}"
    path = Storage::RecordingPaths.root.join(key)
    FileUtils.mkdir_p(path.dirname)
    File.write(path, 'r' * bytes)
    [key, path]
  end

  def call_session(key, metadata = {})
    create(:telephony_call_session, account: account, inbox: inbox, number_binding: number_binding,
                                     recording_ref: key, metadata: metadata)
  end

  def calculate_and_publish
    inventory = described_class.new(account: account)
    usage = nil
    allow(described_class).to receive(:new).and_return(inventory)
    allow(inventory).to(receive(:calculate).and_wrap_original { |method| usage = method.call })
    Accounts::StorageOverviewService.new(account: account).refresh!
    usage
  ensure
    allow(described_class).to receive(:new).and_call_original
  end

  it 'includes compressed stereo audio, retained originals and unlinked files once per physical file' do
    current, = recording_file('stereo.mp3', 64)
    original, original_path = recording_file('stereo.wav', 256)
    recording_file('unlinked.wav', 32)
    recording_file('unlinked-trash.wav', 16, trash: true)
    metadata = {
      'recording' => { 'storage_key' => current, 'byte_size' => 64, 'channel_layout' => 'mixed_stereo',
                       'retained_original' => { 'storage_key' => original, 'byte_size' => 256 } }
    }
    call_session(current, metadata)
    call_session(original, { 'recording' => { 'byte_size' => 256 } })
    File.link(original_path, original_path.dirname.join('hard-link.wav'))
    call_session("voice-recordings/fixture/#{account.id}/hard-link.wav")

    usage = calculate_and_publish

    expect(usage.slice(:active, :trash, :total)).to eq(active: 352, trash: 16, total: 368)
    expect(usage[:by_inbox][inbox.id]).to eq(bytes: 320, count: 2)
    expect(Storage::RecordingPaths).not_to receive(:each_file_with_stat_for_account)
    expect(Storage::RecordingPaths).not_to receive(:resolve)
    expect(described_class.new(account: account).calculate.slice(:active, :trash, :total)).to eq(active: 352, trash: 16, total: 368)
  end

  it 'measures legacy basename and malformed sizes in the background and saves usable fallback metadata' do
    _key, path = recording_file('legacy.wav', 70)
    legacy = call_session('legacy.wav', { 'recording' => { 'byte_size' => 'invalid' } })
    baseline = ActiveRecord::Base.connection.open_transactions
    transaction_depths = []
    allow(Storage::RecordingPaths).to receive(:each_file_with_stat_for_account).and_wrap_original do |method, *args, &block|
      transaction_depths << ActiveRecord::Base.connection.open_transactions
      method.call(*args, &block)
    end

    usage = calculate_and_publish

    expect(usage[:total]).to eq(File.size(path))
    expect(transaction_depths).to eq([baseline])
    expect(legacy.reload.metadata.dig('storage_metrics', 'primary'))
      .to include('ref' => 'legacy.wav', 'byte_size' => 70, 'account_id' => account.id,
                  'key' => "voice-recordings/fixture/#{account.id}/legacy.wav")
    expect(Storage::RecordingPaths).not_to receive(:each_file_with_stat_for_account)
    expect(Storage::RecordingPaths).not_to receive(:resolve)
    expect(described_class.new(account: account).calculate[:total]).to eq(70)
    expect(Accounts::HeavyFilesService.new(account: account, params: { file_type: 'recordings' }).perform.sole[:byte_size]).to eq(70)
  end

  it 'keeps both manifest files in session trash and counts retained-only trash separately from active audio' do
    _key, compressed_trash = recording_file('compressed.mp3', 25, trash: true)
    _key, original_trash = recording_file('original.wav', 100, trash: true)
    call_session(nil, { 'trash' => {
                   'bytes' => 125, 'files' => [{ 'trash_path' => compressed_trash.to_s, 'byte_size' => 25 },
                                               { 'trash_path' => original_trash.to_s, 'byte_size' => 100 }]
                 } })
    current, = recording_file('current.mp3', 50)
    _key, retained_trash = recording_file('retained.wav', 200, trash: true)
    call_session(current, { 'recording' => { 'byte_size' => 50, 'retained_original' => {
                   'storage_key' => "voice-recordings/fixture/#{account.id}/retained.wav", 'byte_size' => 200,
                   'trash' => { 'trash_path' => retained_trash.to_s, 'bytes' => 200 }
                 } } })

    usage = calculate_and_publish

    expect(usage.slice(:active, :trash, :total)).to eq(active: 50, trash: 325, total: 375)
    expect(usage[:by_inbox][inbox.id]).to eq(bytes: 375, count: 4)
  end

  it 'does not count foreign account files, foreign references, external URLs or symlinks' do
    foreign = create(:account)
    foreign_key, foreign_path = recording_file('foreign.wav', 1000, tenant: foreign.id)
    call_session(foreign_key, { 'recording' => { 'byte_size' => 1000 } })
    call_session('https://provider.example/recording.wav', { 'recording' => { 'byte_size' => 9000 } })
    own_key, own_path = recording_file('own.wav', 30)
    call_session(own_key, { 'recording' => { 'byte_size' => 30 } })
    File.symlink(foreign_path, own_path.dirname.join('foreign-link.wav'))

    expect(calculate_and_publish[:total]).to eq(30)
  end

  it 'does not reuse foreign or remote samples to inflate a cached tenant reconciliation' do
    own_key, = recording_file('own.wav', 30)
    call_session(own_key, { 'recording' => { 'byte_size' => 30 } })
    calculate_and_publish
    foreign_id = create(:account).id
    ["voice-recordings/fixture/#{foreign_id}/foreign.wav", 'https://provider.example/remote.wav'].each do |ref|
      sample = { 'ref' => ref, 'account_id' => account.id, 'key' => own_key, 'declared_size' => nil,
                 'byte_size' => 9000, 'identity' => "foreign:#{ref}", 'checked_at' => Time.current.to_i }
      call_session(ref, { 'storage_metrics' => { 'primary' => sample, 'files' => { ref => sample } } })
    end
    expect(Storage::RecordingPaths).not_to receive(:each_file_with_stat_for_account)

    expect(described_class.new(account: account).calculate[:total]).to eq(30)
  end

  it 'reconciles proofless legacy samples once and preserves their measured tenant bytes' do
    key, = recording_file('legacy-proof.wav', 70)
    sample = { 'ref' => 'legacy-proof.wav', 'declared_size' => nil, 'byte_size' => 9000,
               'identity' => 'old:sample', 'checked_at' => Time.current.to_i }
    legacy = call_session('legacy-proof.wav', { 'storage_metrics' => { 'primary' => sample, 'files' => { 'legacy-proof.wav' => sample } } })
    Redis::Alfred.set("account:#{account.id}:recording_reconciliation_v1",
                      JSON.generate(checked_at: Time.current.to_i, identities: {}, unlinked_files: []), ex: 24.hours.to_i)
    expect(Storage::RecordingPaths).to receive(:each_file_with_stat_for_account).once.and_call_original

    expect(calculate_and_publish[:total]).to eq(70)
    expect(legacy.reload.metadata.dig('storage_metrics', 'primary')).to include('account_id' => account.id, 'key' => key, 'byte_size' => 70)
    expect(described_class.new(account: account).calculate[:total]).to eq(70)
  end

  it 'calculates native tenant files with non-hash legacy storage metrics' do
    key, = recording_file('legacy-shape.wav', 30)
    call_session(key, { 'recording' => { 'byte_size' => 30 }, 'storage_metrics' => 'legacy' })

    expect(calculate_and_publish[:total]).to eq(30)
  end

  it 'reconciles new unlinked bytes after the maximum physical audit age' do
    key, = recording_file('known.wav', 30)
    call_session(key, { 'recording' => { 'byte_size' => 30 } })
    calculate_and_publish
    recording_file('later-orphan.wav', 20)

    expect(described_class.new(account: account).calculate[:total]).to eq(30)
    travel_to 25.hours.from_now do
      expect(described_class.new(account: account).calculate[:total]).to eq(50)
    end
  end

  it 'does not count a reconciled unlinked file twice when a session later adopts that same path' do
    key, = recording_file('unlinked.wav', 30)
    expect(calculate_and_publish[:total]).to eq(30)
    call_session(key, { 'recording' => { 'byte_size' => 30 } })
    expect(Storage::RecordingPaths).not_to receive(:each_file_with_stat_for_account)

    usage = described_class.new(account: account).calculate

    expect(usage[:total]).to eq(30)
    expect(usage[:by_inbox][inbox.id]).to eq(bytes: 30, count: 1)
  end

  it 'does not overwrite a concurrent compression while saving fallback measurements' do
    key, = recording_file('old.wav', 50)
    session = call_session(key)
    inventory = described_class.new(account: account)
    inventory.calculate
    new_key, = recording_file('new.mp3', 10)
    session.update!(recording_ref: new_key, metadata: { 'recording' => { 'storage_key' => new_key, 'byte_size' => 10 } })

    inventory.publish!

    expect(session.reload.recording_ref).to eq(new_key)
    expect(session.metadata).to eq('recording' => { 'storage_key' => new_key, 'byte_size' => 10 })
  end
end
