# frozen_string_literal: true

require 'rails_helper'
require 'fileutils'

RSpec.describe Storage::TrashService, type: :service do
  let(:account) { create(:account) }
  let(:service) { described_class.new(account: account) }
  let(:storage_dir) { Rails.root.join('storage', 'voice-recordings', 'test_trash', account.id.to_s) }

  before do
    FileUtils.mkdir_p(storage_dir)
  end

  after do
    FileUtils.rm_rf(storage_dir)
    FileUtils.rm_rf(Rails.root.join('storage', 'trash', account.id.to_s))
  end

  describe '#preview' do
    it 'returns preview data for recordings and attachments' do
      test_file = storage_dir.join('call_1.mp3')
      File.write(test_file, 'sample audio data' * 100)

      session = create(
        :telephony_call_session,
        account: account,
        recording_ref: "voice-recordings/test_trash/#{account.id}/call_1.mp3",
        created_at: 7.months.ago
      )

      res = service.preview(older_than_months: 6)

      expect(res).to include(total_count: 1, recordings_count: 1)
      expect(res[:total_bytes]).to be > 0
      expect(res[:samples].first[:id]).to eq(session.id)
    end
  end

  describe '#move_to_trash! and #restore!' do
    let(:test_file) { storage_dir.join('call_2.mp3') }
    let!(:session) do
      File.write(test_file, 'sample call recording data')
      create(
        :telephony_call_session,
        account: account,
        recording_ref: "voice-recordings/test_trash/#{account.id}/call_2.mp3",
        created_at: 4.months.ago
      )
    end

    it 'moves recording to trash folder' do
      move_res = service.move_to_trash!(older_than_months: 3)

      expect(move_res).to include(success: true, moved_count: 1)
      expect(move_res[:freed_bytes]).to be > 0
      expect(File.exist?(test_file)).to be(false)

      session.reload
      expect(session.recording_ref).to be_nil
      expect(session.metadata['trash']).to be_present
      expect(File.exist?(session.metadata.dig('trash', 'trash_path'))).to be(true)
    end

    it 'restores recording back from trash' do
      service.move_to_trash!(older_than_months: 3)
      session.reload

      restore_res = service.restore!(item_type: 'recording', item_id: session.id)
      expect(restore_res).to include(success: true, restored_count: 1)

      session.reload
      expect(session.recording_ref).to eq("voice-recordings/test_trash/#{account.id}/call_2.mp3")
      expect(session.metadata['trash']).to be_nil
      expect(File.exist?(test_file)).to be(true)
    end

    it 'lists items in trash with days remaining' do
      service.move_to_trash!(older_than_months: 3)

      trash_list = service.list_trash
      expect(trash_list).to include(total_count: 1)
      expect(trash_list[:items].first).to include(id: session.id)
      expect(trash_list[:items].first[:days_remaining]).to be > 0
    end
  end

  describe '#empty_trash!' do
    it 'permanently purges items from disk and marks session purged' do
      test_file = storage_dir.join('call_3.mp3')
      File.write(test_file, 'audio to be permanently purged')

      session = create(
        :telephony_call_session,
        account: account,
        recording_ref: "voice-recordings/test_trash/#{account.id}/call_3.mp3",
        created_at: 4.months.ago
      )

      service.move_to_trash!(older_than_months: 3)
      session.reload
      trash_file = session.metadata.dig('trash', 'trash_path')

      empty_res = service.empty_trash!(purge_all: true)
      expect(empty_res).to include(success: true, purged_count: 1)
      expect(File.exist?(trash_file)).to be(false)

      session.reload
      expect(session.metadata['trash']).to be_nil
      expect(session.metadata.dig('recording', 'purged')).to be(true)
    end
  end

  describe '.purge_expired_all!' do
    it 'purges only expired items older than 30 days' do
      test_file1 = storage_dir.join('expired.mp3')
      File.write(test_file1, 'expired audio')
      trash_dir = Rails.root.join('storage', 'trash', account.id.to_s, 'recordings')
      FileUtils.mkdir_p(trash_dir)
      trash_path1 = trash_dir.join('1_expired.mp3')
      FileUtils.mv(test_file1, trash_path1)

      expired_session = create(
        :telephony_call_session,
        account: account,
        recording_ref: nil,
        metadata: {
          'trash' => {
            'deleted_at' => 35.days.ago.iso8601,
            'expires_at' => 5.days.ago.iso8601,
            'trash_path' => trash_path1.to_s,
            'bytes' => 100
          }
        }
      )

      test_file2 = storage_dir.join('active.mp3')
      File.write(test_file2, 'active audio in trash')
      trash_path2 = trash_dir.join('2_active.mp3')
      FileUtils.mv(test_file2, trash_path2)

      active_trash_session = create(
        :telephony_call_session,
        account: account,
        recording_ref: nil,
        metadata: {
          'trash' => {
            'deleted_at' => 5.days.ago.iso8601,
            'expires_at' => 25.days.from_now.iso8601,
            'trash_path' => trash_path2.to_s,
            'bytes' => 100
          }
        }
      )

      res = described_class.purge_expired_all!

      expect(res[:purged_count]).to eq(1)
      expect(File.exist?(trash_path1)).to be(false)
      expect(File.exist?(trash_path2)).to be(true)

      expired_session.reload
      expect(expired_session.metadata['trash']).to be_nil
      expect(expired_session.metadata.dig('recording', 'purged')).to be(true)

      active_trash_session.reload
      expect(active_trash_session.metadata['trash']).to be_present
    end
  end
end
