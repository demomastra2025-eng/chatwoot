# frozen_string_literal: true

require 'fileutils'
require 'tmpdir'

# Recording and trash specs create and remove files below Storage::RecordingPaths.root. On a server the
# real storage folder holds live recordings (on DEV it is a symlink to the shared volume), so every such
# spec points the root at its own temporary directory and never touches Rails.root/storage.
RSpec.shared_context 'with isolated recording storage' do
  let(:isolated_recording_storage_root) { Pathname.new(Dir.mktmpdir('recording-storage-')).realpath }

  before do
    allow(Storage::RecordingPaths).to receive(:root).and_return(isolated_recording_storage_root)
  end

  after do
    FileUtils.remove_entry(isolated_recording_storage_root.to_s) if File.directory?(isolated_recording_storage_root.to_s)
  end
end
