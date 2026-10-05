# frozen_string_literal: true

require 'rails_helper'

RSpec.describe AccountLimits::StorageUsageService do
  include_context 'with isolated recording storage'

  let(:account) { create(:account) }

  describe 'ActiveStorage ownership queries' do
    it 'counts a tenant logo through a single-column owner subquery' do
      account.logo.attach(io: StringIO.new('l' * 1024), filename: 'tenant-logo.png', content_type: 'image/png')

      expect(described_class.new(account: account).active_storage_bytes).to eq(1024)
    end

    it 'counts variants of tenant-owned blobs but excludes shared user avatars' do
      account.logo.attach(io: StringIO.new('source-image'), filename: 'tenant-logo.png', content_type: 'image/png')
      source_blob = account.logo.blob
      variant = ActiveStorage::VariantRecord.create!(blob: source_blob, variation_digest: 'storage-spec')
      variant.image.attach(io: StringIO.new('derived-image'), filename: 'variant.png', content_type: 'image/png')
      shared_user = create(:user, account: account)
      shared_user.avatar.attach(io: StringIO.new('shared-avatar'), filename: 'avatar.png', content_type: 'image/png')

      expect(described_class.new(account: account).active_storage_bytes)
        .to eq(source_blob.byte_size + variant.image.blob.byte_size)
    end

    it 'honors the attachment-name allowlist for tenant-owned record types' do
      account.logo.attach(io: StringIO.new('allowed logo'), filename: 'tenant-logo.png', content_type: 'image/png')
      excluded_blob = ActiveStorage::Blob.create_before_direct_upload!(
        filename: 'internal-backup.bin',
        byte_size: 8,
        checksum: Digest::MD5.base64digest('excluded'),
        content_type: 'application/octet-stream'
      )
      ActiveStorage::Attachment.create!(record: account, name: 'internal_backup', blob: excluded_blob)

      expect(described_class.new(account: account).active_storage_bytes).to eq(account.logo.blob.byte_size)
    end

    it 'does not convert a database query failure into a false zero' do
      service = described_class.new(account: account)
      allow(service).to receive(:active_storage_blob_scope).and_raise(ActiveRecord::StatementInvalid, 'query failed')

      expect { service.active_storage_bytes }.to raise_error(ActiveRecord::StatementInvalid, 'query failed')
    end

    it 'covers tenant-owned ActiveStorage types and excludes shared user avatars' do
      expect(described_class::RECORD_TYPE_SCOPES).to include(
        'Account' => %w[contacts_export logo],
        'CampaignAudienceImport' => %w[import_file],
        'DataImport' => %w[failed_records import_file],
        'Call' => %w[recording recording_manifest recording_tracks decoded_recording_manifest decoded_recording_chunks]
      )
      expect(described_class::RECORD_TYPE_SCOPES).not_to have_key('User')
    end
  end

  describe '#summary' do
    subject(:summary) { described_class.new(account: account).summary }

    it 'marks storage as unlimited when no account or global limit is configured' do
      expect(summary).to include(
        total_count: ChatwootApp.max_limit,
        current_available: ChatwootApp.max_limit,
        consumed: 0,
        unlimited: true
      )
    end

    it 'treats an explicit storage limit as bounded even when it matches the sentinel value' do
      account.update!(limits: { 'storage_bytes' => ChatwootApp.max_limit })

      expect(summary).to include(
        total_count: ChatwootApp.max_limit,
        current_available: ChatwootApp.max_limit,
        consumed: 0,
        unlimited: false
      )
    end
  end

  describe 'call recordings' do
    let(:recordings_dir) { Storage::RecordingPaths.root.join('voice-recordings', 'janus', account.id.to_s) }

    before do
      FileUtils.mkdir_p(recordings_dir)
      File.write(recordings_dir.join('call.wav'), 'x' * 4096)
    end

    it 'counts local recordings as part of informational physical usage' do
      expect(described_class.new(account: account).usage_bytes).to eq(4096)
    end

    it 'counts a hard-linked recording only once within the tenant tree' do
      File.link(recordings_dir.join('call.wav'), recordings_dir.join('call-copy.wav'))

      expect(described_class.new(account: account).usage_bytes).to eq(4096)
    end

    it 'keeps upload eligibility when physical usage exceeds the configured limit' do
      account.update!(limits: { 'storage_bytes' => 1 })

      expect(described_class.new(account: account).within_limit?(extra_bytes: 10.megabytes)).to be(true)
    end
  end

  describe 'trashed attachments' do
    it 'still count while the file is attached to its message' do
      attachment = create(:message, account: account).attachments.new(account_id: account.id, file_type: :file)
      attachment.file.attach(io: StringIO.new('x' * 1024), filename: 'a.pdf', content_type: 'application/pdf')
      attachment.save!
      attachment.update!(meta: { 'trash' => { 'bytes' => 1024, 'expires_at' => 5.days.from_now.iso8601 } })

      expect(described_class.new(account: account).usage_bytes).to eq(1024)
    end
  end
end
