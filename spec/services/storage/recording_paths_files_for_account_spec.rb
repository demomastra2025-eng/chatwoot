# frozen_string_literal: true

require 'rails_helper'
require 'fileutils'
require 'tmpdir'

RSpec.describe Storage::RecordingPaths, '.files_for_account' do
  let(:account) { create(:account) }
  let(:storage_root) { Pathname.new(Dir.mktmpdir('storage-root')).realpath }
  let(:trash_file) { described_class.trash_root.join(account.id.to_s, 'recordings', 'retained.wav') }

  before { allow(described_class).to receive(:root).and_return(storage_root) }

  after { FileUtils.rm_rf(storage_root) }

  # A fresh checkout or a new server has no storage/voice-recordings folder until the first call is recorded.
  context 'when the storage root has no provider recording directories' do
    before do
      FileUtils.mkdir_p(trash_file.dirname)
      File.write(trash_file, 'r' * 7)
    end

    it 'still lists the files kept in the account trash' do
      expect(described_class.files_for_account(account.id)).to eq([trash_file])
    end

    it 'leaves the trash out when only active recordings are requested' do
      expect(described_class.files_for_account(account.id, include_trash: false)).to be_empty
    end

    it 'lists nothing for an account without any recordings' do
      expect(described_class.files_for_account(create(:account).id)).to be_empty
    end
  end
end
