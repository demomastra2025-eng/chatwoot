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

    it 'rejects an upload when recordings plus the new file exceed the configured limit' do
      account.update!(limits: { 'storage_bytes' => 5000 })

      expect(described_class.new(account: account).within_limit?(extra_bytes: 904)).to be(true)
      expect(described_class.new(account: account).within_limit?(extra_bytes: 905)).to be(false)
    end

    it 'leaves recordings out of the quota when STORAGE_QUOTA_INCLUDE_RECORDINGS is false' do
      account.update!(limits: { 'storage_bytes' => 5000 })

      with_modified_env('STORAGE_QUOTA_INCLUDE_RECORDINGS' => 'false') do
        service = described_class.new(account: account)

        expect(service.usage_bytes).to eq(0)
        expect(service.within_limit?(extra_bytes: 5000)).to be(true)
      end
    end
  end

  describe '#within_limit?' do
    subject(:service) { described_class.new(account: account) }

    it 'always allows uploads when no account or global limit is configured' do
      expect(service.within_limit?(extra_bytes: 10.terabytes)).to be(true)
    end

    it 'allows an upload that fits under the account limit' do
      account.update!(limits: { 'storage_bytes' => 10.megabytes })

      expect(service.within_limit?(extra_bytes: 9.megabytes)).to be(true)
    end

    it 'rejects an upload that would push the account over its limit' do
      account.update!(limits: { 'storage_bytes' => 10.megabytes })

      expect(service.within_limit?(extra_bytes: 11.megabytes)).to be(false)
    end

    it 'counts bytes already stored against the limit' do
      account.update!(limits: { 'storage_bytes' => 2048 })
      account.logo.attach(io: StringIO.new('l' * 1024), filename: 'tenant-logo.png', content_type: 'image/png')

      expect(service.within_limit?(extra_bytes: 1024)).to be(true)
      expect(service.within_limit?(extra_bytes: 1025)).to be(false)
    end

    it 'credits the bytes released by a replaced file' do
      account.update!(limits: { 'storage_bytes' => 2048 })
      account.logo.attach(io: StringIO.new('l' * 2048), filename: 'tenant-logo.png', content_type: 'image/png')

      expect(service.within_limit?(extra_bytes: 1, released_bytes: 0)).to be(false)
      expect(service.within_limit?(extra_bytes: 1500, released_bytes: 2048)).to be(true)
    end

    it 'uses the global limit when the account has none' do
      account
      allow(GlobalConfig).to receive(:get).and_call_original
      allow(GlobalConfig).to receive(:get).with('ACCOUNT_STORAGE_BYTES_LIMIT').and_return('ACCOUNT_STORAGE_BYTES_LIMIT' => 1000)

      expect(service.within_limit?(extra_bytes: 1000)).to be(true)
      expect(service.within_limit?(extra_bytes: 1001)).to be(false)
    end
  end

  describe 'incoming attachments' do
    let(:conversation) { create(:conversation, account: account) }

    before { account.update!(limits: { 'storage_bytes' => 1 }) }

    def build_attachment(skip: false)
      message = create(:message, account: account, inbox: conversation.inbox, conversation: conversation, message_type: :incoming)
      attachment = message.attachments.new(account_id: account.id, file_type: :image)
      attachment.skip_storage_limit_validation! if skip
      attachment.file.attach(io: Rails.root.join('spec/assets/avatar.png').open, filename: 'avatar.png', content_type: 'image/png')
      attachment
    end

    it 'blocks a regular attachment when the account is over its limit' do
      attachment = build_attachment

      expect(attachment).not_to be_valid
      expect(attachment.errors[:file]).to include(described_class::LIMIT_EXCEEDED_MESSAGE)
    end

    it 'saves an incoming attachment that is exempt from the storage limit' do
      attachment = build_attachment(skip: true)

      expect(attachment.save).to be(true)
      expect(attachment.reload.file).to be_attached
    end

    it 'never validates an incoming call recording against the limit' do
      call = create(:call, account: account)

      call.recording.attach(io: StringIO.new('r' * 4096), filename: 'call.ogg', content_type: 'audio/ogg')

      expect(call.reload.recording).to be_attached
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
