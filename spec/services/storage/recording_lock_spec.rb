# frozen_string_literal: true

require 'rails_helper'
require 'fileutils'
require 'timeout'

RSpec.describe Storage::RecordingLock do
  self.use_transactional_tests = false

  it 'serializes workers that mutate the same tenant recording' do
    account_id = SecureRandom.random_number(2**31)
    key = "voice-recordings/lock-spec/#{account_id}/shared.wav"
    storage_file = Rails.root.join('storage', key)
    FileUtils.mkdir_p(storage_file.dirname)
    File.write(storage_file, 'synthetic lock fixture')
    other_provider_file = Rails.root.join('storage', 'voice-recordings', 'sipuni', account_id.to_s, 'shared.wav')
    FileUtils.mkdir_p(other_provider_file.dirname)
    File.write(other_provider_file, 'a different physical fixture')
    other_provider_key = "voice-recordings/sipuni/#{account_id}/shared.wav"
    target_key = "voice-recordings/lock-spec/#{account_id}/final.mp3"
    missing_target_identity = Storage::RecordingPaths.canonical_lock_identity(target_key, account_id: account_id)
    source_lock_identity = Storage::RecordingPaths.canonical_lock_identity(key, account_id: account_id)
    expect(source_lock_identity)
      .to eq(Storage::RecordingPaths.canonical_lock_identity('shared.wav', account_id: account_id))
    expect(source_lock_identity)
      .to eq(Storage::RecordingPaths.canonical_lock_identity(storage_file.to_s, account_id: account_id))
    expect(source_lock_identity)
      .to eq(Storage::RecordingPaths.canonical_lock_identity(other_provider_key, account_id: account_id))
    expect(Storage::RecordingPaths.same_physical_file?(key, other_provider_key, account_id: account_id)).to be(false)
    first_entered = Queue.new
    second_started = Queue.new
    second_entered = Queue.new
    release_first = Queue.new

    first = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        described_class.synchronize(account_id: account_id, storage_keys: [key]) do
          first_entered << true
          Timeout.timeout(10) { release_first.pop }
        end
      end
    end
    Timeout.timeout(5) { first_entered.pop }

    trash_dir = Storage::RecordingPaths.prepare_trash_directory(account_id)
    trash_path = trash_dir.join('lock-spec_shared.wav')
    File.rename(storage_file, trash_path)
    expect(Storage::RecordingPaths.canonical_lock_identity(key, account_id: account_id))
      .to eq(source_lock_identity)
    expect(Storage::RecordingPaths.canonical_lock_identity('shared.wav', account_id: account_id))
      .to eq(source_lock_identity)
    expect(Storage::RecordingPaths.canonical_lock_identity(storage_file.to_s, account_id: account_id))
      .to eq(source_lock_identity)
    expect(Storage::RecordingPaths.reference_aliases(storage_file.to_s, account_id: account_id, allow_missing: true))
      .to include(key, 'shared.wav')

    second = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        second_started << true
        described_class.synchronize(account_id: account_id, storage_keys: ['shared.wav']) { second_entered << true }
      end
    end
    Timeout.timeout(5) { second_started.pop }
    sleep 0.1
    expect(second_entered.empty?).to be(true)

    release_first << true
    expect(Timeout.timeout(5) { second_entered.pop }).to be(true)
    temporary_target = storage_file.dirname.join('final.mp3.publishing')
    File.write(temporary_target, 'published fixture')
    File.rename(temporary_target, storage_file.dirname.join('final.mp3'))
    expect(Storage::RecordingPaths.canonical_lock_identity(target_key, account_id: account_id))
      .to eq(missing_target_identity)

    [first, second].each { |thread| expect(thread.join(5)).to be(thread) }
  ensure
    release_first << true if release_first
    [first, second].compact.each do |thread|
      next unless thread.alive?

      thread.join(5)
      thread.kill if thread.alive?
    end
    FileUtils.rm_rf(storage_file.dirname) if defined?(storage_file)
    FileUtils.rm_rf(other_provider_file.dirname) if defined?(other_provider_file)
    FileUtils.rm_rf(Storage::RecordingPaths.trash_root.join(account_id.to_s)) if defined?(account_id)
  end
end
