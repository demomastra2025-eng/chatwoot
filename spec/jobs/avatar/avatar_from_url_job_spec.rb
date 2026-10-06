require 'rails_helper'

RSpec.describe Avatar::AvatarFromUrlJob do
  let(:file) { fixture_file_upload(Rails.root.join('spec/assets/avatar.png'), 'image/png') }
  let(:safe_fetch_result) { SafeFetch::Result.new(tempfile: file.tempfile, filename: file.original_filename, content_type: file.content_type) }
  let(:valid_url) { 'https://example.com/avatar.png' }

  it 'enqueues the job' do
    contact = create(:contact)
    expect { described_class.perform_later(contact, 'https://example.com/avatar.png') }
      .to have_enqueued_job(described_class).on_queue('default')
  end

  it 'keeps non-contact avatar jobs on the purgable queue' do
    agent_bot = create(:agent_bot)

    expect { described_class.perform_later(agent_bot, 'https://example.com/avatar.png') }
      .to have_enqueued_job(described_class).on_queue('purgable')
  end

  context 'with rate-limited avatarable (Contact)' do
    let(:avatarable) { create(:contact) }

    it 'attaches through SafeFetch and updates sync attributes' do
      expect(SafeFetch).to receive(:fetch).with(
        valid_url,
        max_bytes: Avatar::AvatarFromUrlJob::MAX_DOWNLOAD_SIZE,
        allowed_content_type_prefixes: [],
        allowed_content_types: Avatarable::ALLOWED_AVATAR_CONTENT_TYPES
      ).and_yield(safe_fetch_result)

      described_class.perform_now(avatarable, valid_url)
      avatarable.reload
      expect(avatarable.avatar).to be_attached
      expect(avatarable.additional_attributes['avatar_url_hash']).to eq(Digest::SHA256.hexdigest(valid_url))
      expect(avatarable.additional_attributes['last_avatar_sync_at']).to be_present
    end

    it 'attaches the avatar of an inbound customer when the account is over its storage limit' do
      avatarable.account.update!(limits: { 'storage_bytes' => 1 })
      allow(SafeFetch).to receive(:fetch).and_yield(safe_fetch_result)

      described_class.perform_now(avatarable, valid_url)

      avatarable.reload
      expect(avatarable.avatar).to be_attached
      expect(avatarable.additional_attributes['avatar_url_hash']).to eq(Digest::SHA256.hexdigest(valid_url))
    end

    it 'keeps the storage limit for an avatar a staff member uploads for the same contact' do
      avatarable.account.update!(limits: { 'storage_bytes' => 1 })

      expect(avatarable.avatar.attach(io: file.tempfile, filename: 'avatar.png', content_type: 'image/png')).to be_nil
      expect(avatarable.reload.avatar).not_to be_attached
    end

    it 'does not record the URL hash when the avatar could not be saved, so the same URL is fetched again later' do
      # ActiveStorage identifies the type from the content, so the fetched file has to be a real PDF to be refused.
      pdf = Tempfile.new(['avatar', '.pdf'])
      pdf.write("%PDF-1.4\n%%EOF\n")
      pdf.rewind
      unsupported = SafeFetch::Result.new(tempfile: pdf, filename: 'avatar.pdf', content_type: 'application/pdf')
      allow(SafeFetch).to receive(:fetch).and_yield(unsupported)

      described_class.perform_now(avatarable, valid_url)

      avatarable.reload
      expect(avatarable.avatar).not_to be_attached
      expect(avatarable.additional_attributes['last_avatar_sync_at']).to be_present
      expect(avatarable.additional_attributes['avatar_url_hash']).to be_nil
    ensure
      pdf&.close!
    end

    it 'returns early when rate limited' do
      ts = 30.seconds.ago.iso8601
      avatarable.update(additional_attributes: { 'last_avatar_sync_at' => ts })
      expect(SafeFetch).not_to receive(:fetch)
      described_class.perform_now(avatarable, valid_url)
      avatarable.reload
      expect(avatarable.avatar).not_to be_attached
      expect(avatarable.additional_attributes['last_avatar_sync_at']).to be_present
      expect(Time.zone.parse(avatarable.additional_attributes['last_avatar_sync_at']))
        .to be > Time.zone.parse(ts)
      expect(avatarable.additional_attributes['avatar_url_hash']).to eq(Digest::SHA256.hexdigest(valid_url))
    end

    it 'returns early when hash unchanged' do
      avatarable.update(additional_attributes: { 'avatar_url_hash' => Digest::SHA256.hexdigest(valid_url) })
      expect(SafeFetch).not_to receive(:fetch)
      described_class.perform_now(avatarable, valid_url)
      expect(avatarable.avatar).not_to be_attached
      avatarable.reload
      expect(avatarable.additional_attributes['last_avatar_sync_at']).to be_present
      expect(avatarable.additional_attributes['avatar_url_hash']).to eq(Digest::SHA256.hexdigest(valid_url))
    end

    it 'updates sync attributes even when URL is invalid' do
      invalid_url = 'invalid_url'
      expect(SafeFetch).not_to receive(:fetch)
      described_class.perform_now(avatarable, invalid_url)
      avatarable.reload
      expect(avatarable.avatar).not_to be_attached
      expect(avatarable.additional_attributes['last_avatar_sync_at']).to be_present
      expect(avatarable.additional_attributes['avatar_url_hash']).to eq(Digest::SHA256.hexdigest(invalid_url))
    end

    it 'updates sync attributes when fetched file is invalid' do
      invalid_result = SafeFetch::Result.new(tempfile: Tempfile.new(['invalid', '.xml']), filename: nil, content_type: 'application/xml')
      expect(SafeFetch).to receive(:fetch).and_yield(invalid_result)

      expect { described_class.perform_now(avatarable, valid_url) }.not_to raise_error
      avatarable.reload

      expect(avatarable.avatar).not_to be_attached
      expect(avatarable.additional_attributes['last_avatar_sync_at']).to be_present
      expect(avatarable.additional_attributes['avatar_url_hash']).to eq(Digest::SHA256.hexdigest(valid_url))
    ensure
      invalid_result&.tempfile&.close!
    end
  end

  context 'with regular avatarable' do
    let(:avatarable) { create(:agent_bot) }

    it 'downloads through SafeFetch and attaches avatar' do
      expect(SafeFetch).to receive(:fetch).with(
        valid_url,
        max_bytes: Avatar::AvatarFromUrlJob::MAX_DOWNLOAD_SIZE,
        allowed_content_type_prefixes: [],
        allowed_content_types: Avatarable::ALLOWED_AVATAR_CONTENT_TYPES
      ).and_yield(safe_fetch_result)

      described_class.perform_now(avatarable, valid_url)
      expect(avatarable.avatar).to be_attached
    end
  end

  it 'logs not-found HTTP errors without raising' do
    contact = create(:contact)
    expect(SafeFetch).to receive(:fetch).and_raise(SafeFetch::HttpError, '404 Not Found')

    expect { described_class.perform_now(contact, valid_url) }.not_to raise_error
  end

  it 'skips sync attribute updates when URL is nil' do
    contact = create(:contact)
    expect(SafeFetch).not_to receive(:fetch)

    expect { described_class.perform_now(contact, nil) }.not_to raise_error

    contact.reload
    expect(contact.additional_attributes['last_avatar_sync_at']).to be_nil
    expect(contact.additional_attributes['avatar_url_hash']).to be_nil
  end
end
