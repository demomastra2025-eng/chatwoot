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
    user = create(:user)

    expect { described_class.perform_later(user, 'https://example.com/avatar.png') }
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
    let(:avatarable) { create(:user) }

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
