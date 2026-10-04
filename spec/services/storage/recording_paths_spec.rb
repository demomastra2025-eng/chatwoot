# frozen_string_literal: true

require 'rails_helper'
require 'fileutils'

RSpec.describe Storage::RecordingPaths do
  let(:account) { create(:account) }
  let(:other_account) { create(:account) }
  let(:voice_root) { described_class.root.join('voice-recordings') }
  let(:provider_root) { voice_root.join('janus') }
  let(:account_root) { provider_root.join(account.id.to_s) }

  before { FileUtils.mkdir_p(account_root) }

  after do
    FileUtils.rm_rf(account_root)
    FileUtils.rm_rf(voice_root.join(account.id.to_s))
    FileUtils.rm_rf(voice_root.join(other_account.id.to_s))
    FileUtils.rm_rf(provider_root.join(other_account.id.to_s))
    FileUtils.rm_rf(described_class.trash_root.join(account.id.to_s))
    FileUtils.rm_rf(described_class.trash_root.join(other_account.id.to_s))
  end

  it 'counts account-first and provider/account files but skips other numeric account roots' do
    provider_file = account_root.join('provider.wav')
    account_first = voice_root.join(account.id.to_s, 'whatsapp.mp3')
    unrelated_numeric_tree = voice_root.join(other_account.id.to_s, account.id.to_s, 'foreign.wav')
    FileUtils.mkdir_p(account_first.dirname)
    FileUtils.mkdir_p(unrelated_numeric_tree.dirname)
    File.write(provider_file, 'p' * 11)
    File.write(account_first, 'a' * 13)
    File.write(unrelated_numeric_tree, 'x' * 100)

    result = described_class.files_for_account(account.id)

    expect(result.sum { |path| File.size(path) }).to eq(24)
    expect(result).not_to include(unrelated_numeric_tree)
  end

  it 'does not resolve another account path or a traversal key' do
    foreign = provider_root.join(other_account.id.to_s, 'recording.wav')
    FileUtils.mkdir_p(foreign.dirname)
    File.write(foreign, 'foreign')

    expect(described_class.resolve("voice-recordings/janus/#{other_account.id}/recording.wav", account_id: account.id)).to be_nil
    expect(described_class.resolve('../janus/recording.wav', account_id: account.id)).to be_nil
  end

  it 'resolves qualified nested paths and fails closed on provider basename collisions' do
    first = account_root.join('nested', 'call.wav')
    second_root = voice_root.join('sipuni', account.id.to_s)
    second = second_root.join('nested', 'call.wav')
    FileUtils.mkdir_p(first.dirname)
    FileUtils.mkdir_p(second.dirname)
    File.write(first, 'janus audio')
    File.write(second, 'sipuni audio')
    first_key = first.relative_path_from(Storage::RecordingPaths.root).to_s

    expect(described_class.resolve(first_key, account_id: account.id)).to eq(first)
    expect(described_class.resolve('nested/call.wav', account_id: account.id)).to be_nil
    expect(described_class.resolve('call.wav', account_id: account.id)).to be_nil
  ensure
    FileUtils.rm_rf(second_root) if defined?(second_root)
  end

  it 'resolves safe absolute recording references only within the owning tenant root' do
    file = account_root.join('absolute.wav')
    File.write(file, 'tenant audio')
    foreign = provider_root.join(other_account.id.to_s, 'absolute.wav')
    FileUtils.mkdir_p(foreign.dirname)
    File.write(foreign, 'foreign audio')

    expect(described_class.resolve(file.to_s, account_id: account.id)).to eq(file)
    expect(described_class.resolve(foreign.to_s, account_id: account.id)).to be_nil
    expect(described_class.reference_aliases(file.to_s, account_id: account.id)).to include(file.to_s, 'absolute.wav')
  end

  it 'rejects symlink leaves and nested symlink directories when scanning or resolving' do
    outside = Rails.root.join('tmp', "other-recordings-#{account.id}")
    FileUtils.mkdir_p(outside)
    foreign = outside.join('recording.wav')
    File.write(foreign, 'outside')
    File.symlink(foreign.to_s, account_root.join('leaf.wav').to_s)
    File.symlink(outside.to_s, account_root.join('nested').to_s)

    expect(described_class.files_for_account(account.id)).to be_empty
    expect(described_class.resolve("voice-recordings/janus/#{account.id}/leaf.wav", account_id: account.id)).to be_nil
    expect(described_class.resolve("voice-recordings/janus/#{account.id}/nested/recording.wav", account_id: account.id)).to be_nil
  rescue NotImplementedError, Errno::EPERM
    skip 'Symlinks are not supported by this environment'
  ensure
    FileUtils.rm_rf(account_root.join('leaf.wav'))
    FileUtils.rm_rf(account_root.join('nested'))
    FileUtils.rm_rf(outside) if outside
  end

  it 'rejects a restore destination whose existing parent is a symlink' do
    outside = Rails.root.join('tmp', "restore-target-#{account.id}")
    FileUtils.mkdir_p(outside)
    File.symlink(outside.to_s, account_root.join('redirect').to_s)

    expect(described_class.within_account?(account_root.join('redirect', 'restore.wav'), account_id: account.id)).to be(false)
    expect(described_class.within_account?(account_root.join('new', 'restore.wav'), account_id: account.id)).to be(true)
  rescue NotImplementedError, Errno::EPERM
    skip 'Symlinks are not supported by this environment'
  ensure
    FileUtils.rm_rf(account_root.join('redirect'))
    FileUtils.rm_rf(outside) if outside
  end

  it 'refuses to create an account trash tree below a symlink' do
    account_trash_parent = described_class.trash_root.join(account.id.to_s)
    FileUtils.mkdir_p(account_trash_parent.dirname)
    outside = Rails.root.join('tmp', "trash-target-#{account.id}")
    FileUtils.mkdir_p(outside)
    File.symlink(outside.to_s, account_trash_parent.to_s)

    expect { described_class.prepare_trash_directory(account.id) }.to raise_error(ArgumentError)
    expect(Dir.children(outside)).to be_empty
  rescue NotImplementedError, Errno::EPERM
    skip 'Symlinks are not supported by this environment'
  ensure
    FileUtils.rm_rf(account_trash_parent) if account_trash_parent
    FileUtils.rm_rf(outside) if outside
  end

  it 'rejects symlink ancestors inside the trusted storage root, including trash account directories' do
    other_trash = described_class.trash_root.join(other_account.id.to_s)
    FileUtils.mkdir_p(other_trash.join('recordings'))
    foreign_file = other_trash.join('recordings', 'foreign.mp3')
    File.write(foreign_file, 'foreign audio')

    account_trash = described_class.trash_root.join(account.id.to_s)
    FileUtils.rm_rf(account_trash)
    File.symlink(other_trash.to_s, account_trash.to_s)

    expect(described_class.resolve_trash(foreign_file.to_s, account_id: account.id)).to be_nil
    expect(described_class.files_for_account(account.id)).not_to include(foreign_file)
  rescue NotImplementedError, Errno::EPERM
    skip 'Symlinks are not supported by this environment'
  ensure
    FileUtils.rm_rf(described_class.trash_root.join(account.id.to_s)) if account
  end
end
