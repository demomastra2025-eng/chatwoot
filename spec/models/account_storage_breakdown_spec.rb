# frozen_string_literal: true

require 'rails_helper'
require 'fileutils'

RSpec.describe Account, type: :model do
  include_context 'with isolated recording storage'

  let(:account) { create(:account) }

  it 'returns an explicit pending breakdown on a cold read without filesystem traversal' do
    Redis::Alfred.delete("account:#{account.id}:storage_overview_v1")
    expect(Storage::RecordingPaths).not_to receive(:each_file_with_stat_for_account)
    expect(Storage::RecordingPaths).not_to receive(:files_for_account)

    expect(account.storage_breakdown).to include(calculating: true, total: nil, recordings: nil)
  ensure
    Redis::Alfred.delete("account:#{account.id}:storage_overview_pending_v2")
  end

  it 'deduplicates shared attachment blobs across categories and inboxes' do
    inboxes = create_list(:inbox, 2, account: account)
    blob = ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new('shared-physical-blob' * 50),
      filename: 'shared.pdf',
      content_type: 'application/pdf'
    )

    inboxes.each do |inbox|
      message = create(:message, account: account, inbox: inbox)
      attachment = message.attachments.new(account_id: account.id, file_type: :file)
      attachment.file.attach(blob)
      attachment.save!
    end
    trash_reference = create(:message, account: account, inbox: inboxes.first).attachments.new(
      account_id: account.id, file_type: :file, meta: { 'trash' => { 'deleted_at' => Time.current.iso8601 } }
    )
    trash_reference.file.attach(blob)
    trash_reference.save!
    trash_blob = ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new('trash-only-blob'),
      filename: 'trash-only.pdf',
      content_type: 'application/pdf'
    )
    trash_message = create(:message, account: account, inbox: inboxes.last)
    trash_attachment = trash_message.attachments.new(
      account_id: account.id, file_type: :file, meta: { 'trash' => { 'deleted_at' => Time.current.iso8601 } }
    )
    trash_attachment.file.attach(trash_blob)
    trash_attachment.save!

    trash_path = Storage::RecordingPaths.trash_root.join(account.id.to_s, 'recordings', 'retained.wav')
    FileUtils.mkdir_p(trash_path.dirname)
    File.write(trash_path, 'trashed recording')
    create(
      :telephony_call_session,
      account: account,
      inbox: inboxes.first,
      recording_ref: nil,
      metadata: {
        'trash' => {
          'files' => [{ 'storage_key' => "voice-recordings/tenant/#{account.id}/retained.wav", 'trash_path' => trash_path.to_s }],
          'trash_path' => trash_path.to_s,
          'bytes' => File.size(trash_path)
        }
      }
    )

    breakdown = account.calculate_storage_breakdown
    category_total = %i[recordings audio images videos documents captain other trash].sum { |key| breakdown[key] }
    inbox_total = breakdown[:by_inbox].sum { |row| row[:bytes] }

    expect(breakdown[:documents]).to eq(blob.byte_size)
    expect(breakdown[:trash]).to eq(trash_blob.byte_size + File.size(trash_path))
    expect(category_total).to eq(breakdown[:total])
    expect(inbox_total).to eq(breakdown[:total])
    expect(breakdown[:by_inbox].sum { |row| row[:files_count] }).to eq(3)
  end

  describe 'inbox rows with a non-inbox byte source and a recording' do
    let(:inbox) { create(:inbox, account: account) }

    before do
      account.logo.attach(io: StringIO.new('l' * 1000), filename: 'logo.png', content_type: 'image/png')
      trash_path = Storage::RecordingPaths.trash_root.join(account.id.to_s, 'recordings', 'retained.wav')
      FileUtils.mkdir_p(trash_path.dirname)
      File.write(trash_path, 'r' * 2000)
      create(
        :telephony_call_session,
        account: account,
        inbox: inbox,
        recording_ref: nil,
        metadata: { 'trash' => { 'files' => [{ 'trash_path' => trash_path.to_s }], 'trash_path' => trash_path.to_s, 'bytes' => 2000 } }
      )
    end

    it 'adds up to the total with the default quota flag' do
      breakdown = account.calculate_storage_breakdown

      expect(breakdown[:total]).to eq(3000)
      expect(breakdown[:by_inbox].sum { |row| row[:bytes] }).to eq(3000)
      expect(breakdown[:by_inbox].find { |row| row[:id].nil? }[:bytes]).to eq(1000)
    end

    it 'adds up to the total when recordings count towards the quota' do
      with_modified_env('STORAGE_QUOTA_INCLUDE_RECORDINGS' => 'true') do
        breakdown = account.calculate_storage_breakdown

        expect(breakdown[:total]).to eq(3000)
        expect(breakdown[:by_inbox].sum { |row| row[:bytes] }).to eq(3000)
      end
    end
  end
end
