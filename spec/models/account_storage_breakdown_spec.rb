# frozen_string_literal: true

require 'rails_helper'
require 'fileutils'

RSpec.describe Account, type: :model do
  let(:account) { create(:account) }

  after do
    FileUtils.rm_rf(Rails.root.join('storage', 'trash', account.id.to_s))
    FileUtils.rm_rf(Rails.root.join('storage', 'voice-recordings', 'tenant', account.id.to_s))
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

    trash_path = Rails.root.join('storage/trash', account.id.to_s, 'recordings', 'retained.wav')
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
end
