require 'rails_helper'

RSpec.describe Whatsapp::TemplateAssetUploadService do
  let(:whatsapp_channel) { instance_double(Channel::Whatsapp, account_id: 1, provider_config: provider_config) }
  let(:provider_config) do
    {
      'api_key' => 'test-access-token',
      'business_account_id' => 'waba-123',
      'phone_number_id' => 'phone-123'
    }
  end
  let(:service) { described_class.new(whatsapp_channel: whatsapp_channel) }

  before do
    allow(GlobalConfigService).to receive(:load).with('WHATSAPP_APP_ID', '').and_return('app-123')
    allow(GlobalConfigService).to receive(:load).with('WHATSAPP_API_VERSION', 'v25.0').and_return('v22.0')
  end

  describe '.find_upload_blob!' do
    let(:legacy_blob) { instance_double(ActiveStorage::Blob, metadata: legacy_metadata) }
    let(:legacy_metadata) { { 'account_id' => 1 } }
    let(:invalid_signature) { ActiveSupport::MessageVerifier::InvalidSignature.new }

    before do
      allow(ActiveStorage::Blob).to receive(:find_signed!)
        .with('legacy-blob', purpose: 'whatsapp_template_media:account:1')
        .and_raise(invalid_signature)
      allow(ActiveStorage::Blob).to receive(:find_signed!).with('legacy-blob').and_return(legacy_blob)
    end

    it 'accepts an account-owned generic blob id emitted by the old upload API' do
      expect(described_class.find_upload_blob!('legacy-blob', account_id: 1)).to eq(legacy_blob)
    end

    it 'rejects a generic blob id owned by another account' do
      legacy_metadata['account_id'] = 2

      expect do
        described_class.find_upload_blob!('legacy-blob', account_id: 1)
      end.to raise_error(described_class::BlobReferenceRejectedError)
    end

    it 'rejects a generic blob lookup when template-purpose metadata is present' do
      legacy_metadata['upload_purpose'] = described_class::UPLOAD_PURPOSE

      expect do
        described_class.find_upload_blob!('legacy-blob', account_id: 1)
      end.to raise_error(described_class::BlobReferenceRejectedError)
    end

    it 'classifies a valid account-scoped reference whose record is gone as unavailable' do
      allow(ActiveStorage::Blob).to receive(:find_signed!)
        .with('missing-blob', purpose: 'whatsapp_template_media:account:1')
        .and_raise(ActiveRecord::RecordNotFound)

      expect do
        described_class.find_upload_blob!('missing-blob', account_id: 1)
      end.to raise_error(described_class::BlobReferenceUnavailableError)
    end

    it 'classifies a tampered or foreign-purpose reference as rejected' do
      allow(ActiveStorage::Blob).to receive(:find_signed!)
        .with('rejected-blob', purpose: 'whatsapp_template_media:account:1')
        .and_raise(invalid_signature)
      allow(ActiveStorage::Blob).to receive(:find_signed!).with('rejected-blob').and_raise(invalid_signature)

      expect do
        described_class.find_upload_blob!('rejected-blob', account_id: 1)
      end.to raise_error(described_class::BlobReferenceRejectedError)
    end

    it 'rejects a missing legacy generic blob instead of allowing a rolling URL fallback' do
      allow(ActiveStorage::Blob).to receive(:find_signed!)
        .with('missing-legacy-blob', purpose: 'whatsapp_template_media:account:1')
        .and_raise(invalid_signature)
      allow(ActiveStorage::Blob).to receive(:find_signed!).with('missing-legacy-blob').and_raise(ActiveRecord::RecordNotFound)

      expect do
        described_class.find_upload_blob!('missing-legacy-blob', account_id: 1)
      end.to raise_error(described_class::BlobReferenceRejectedError)
    end
  end

  describe '.schedule_cleanup' do
    it 'uses the attachment-aware cleanup job with the blob id' do
      blob = instance_double(ActiveStorage::Blob, id: 42)
      configured_job = instance_double(ActiveJob::ConfiguredJob)
      expect(Whatsapp::TemplateMediaCleanupJob).to receive(:set).with(wait: described_class::CLEANUP_DELAY).and_return(configured_job)
      expect(configured_job).to receive(:perform_later).with(42)

      described_class.schedule_cleanup(blob)
    end
  end

  describe '#upload' do
    it 'blocks localhost sample media urls before downloading' do
      expect do
        service.upload(url: 'http://localhost:3000/sample.jpg', media_type: 'image')
      end.to raise_error(ArgumentError, 'Sample media URL must use port 80 or 443')
    end

    it 'blocks hosts that resolve to private addresses' do
      allow(Resolv).to receive(:getaddresses).with('assets.example.com').and_return(['127.0.0.1'])

      expect do
        service.upload(url: 'https://assets.example.com/sample.jpg', media_type: 'image')
      end.to raise_error(ArgumentError, 'Sample media URL could not be downloaded safely: resolved to a non-public address')
    end

    it 'blocks non-http urls' do
      expect do
        service.upload(url: 'file:///tmp/sample.jpg', media_type: 'image')
      end.to raise_error(ArgumentError, 'Sample media URL must start with http:// or https://')
    end

    it 'blocks credentials and non-web ports before fetching' do
      expect(SafeFetch).not_to receive(:fetch)

      expect do
        service.upload(url: 'https://user:secret@assets.example.com/sample.jpg', media_type: 'image')
      end.to raise_error(ArgumentError, 'Sample media URL cannot include credentials')

      expect do
        service.upload(url: 'https://assets.example.com:8443/sample.jpg', media_type: 'image')
      end.to raise_error(ArgumentError, 'Sample media URL must use port 80 or 443')
    end

    it 'uploads a public image through the pinned safe fetcher without redirects' do
      file = Tempfile.new(['sample', '.jpg'])
      file.write('sample-image')
      file.rewind
      result = SafeFetch::Result.new(tempfile: file, filename: 'sample.jpg', content_type: 'image/jpeg')
      allow(SafeFetch).to receive(:fetch)
        .with(
          'https://cdn.example.com/sample.jpg',
          max_bytes: described_class::MAX_DOWNLOAD_SIZE,
          redirects_remaining: 0,
          validate_content_type: false
        )
        .and_yield(result)
      allow(Marcel::MimeType).to receive(:for).with(file).and_return('image/jpeg')

      upload_session_response = instance_double(HTTParty::Response, success?: true, parsed_response: { 'id' => 'upload-session-123' })
      upload_response = instance_double(HTTParty::Response, success?: true, parsed_response: { 'h' => 'uploaded-handle-123' })
      allow(HTTParty).to receive(:post).and_return(upload_session_response, upload_response)

      expect(service.upload(url: 'https://cdn.example.com/sample.jpg', media_type: 'image')).to eq('uploaded-handle-123')
    ensure
      file&.close!
    end

    it 'does not call Meta when an image extension hides unrecognized bytes' do
      file = Tempfile.new(['sample', '.jpg'])
      file.write('not-valid-image-bytes')
      file.rewind
      result = SafeFetch::Result.new(tempfile: file, filename: 'sample.jpg', content_type: 'image/jpeg')
      allow(SafeFetch).to receive(:fetch).and_yield(result)
      expect(HTTParty).not_to receive(:post)

      expect do
        service.upload(url: 'https://cdn.example.com/sample.jpg', media_type: 'image')
      end.to raise_error(ArgumentError, 'Unsupported image file type: application/octet-stream')
    ensure
      file&.close!
    end

    it 'redacts credentials from provider upload errors' do
      response = instance_double(
        HTTParty::Response,
        success?: false,
        body: '{"error":"access_token=test-access-token"}'
      )

      expect do
        service.send(:parse_response, response, 'Upload failed')
      end.to raise_error(RuntimeError) { |error|
        expect(error.message).to include('[FILTERED]')
        expect(error.message).not_to include('test-access-token')
      }
    end
  end

  describe '#upload_blob' do
    it 'uploads an account-owned blob without requiring a public URL' do
      file = Tempfile.new(['invoice', '.pdf'])
      file.write('sample-pdf')
      file.rewind
      blob = instance_double(
        ActiveStorage::Blob,
        byte_size: file.size,
        content_type: 'application/pdf',
        filename: ActiveStorage::Filename.new('invoice.pdf'),
        attachments: instance_double(ActiveRecord::Associations::CollectionProxy, exists?: false)
      )
      allow(blob).to receive(:open).and_yield(file)
      allow(described_class).to receive(:find_upload_blob!).with('signed-blob', account_id: 1).and_return(blob)
      allow(Marcel::MimeType).to receive(:for).with(file).and_return('application/pdf')

      upload_session_response = instance_double(HTTParty::Response, success?: true, parsed_response: { 'id' => 'upload-session-123' })
      upload_response = instance_double(HTTParty::Response, success?: true, parsed_response: { 'h' => 'uploaded-handle-123' })
      allow(HTTParty).to receive(:post).and_return(upload_session_response, upload_response)

      expect(service.upload_blob(blob_signed_id: 'signed-blob', media_type: 'document')).to eq('uploaded-handle-123')
    ensure
      file&.close!
    end

    it 'does not call Meta when a blob image extension hides unrecognized bytes' do
      file = Tempfile.new(['sample', '.jpg'])
      file.write('not-valid-image-bytes')
      file.rewind
      blob = instance_double(
        ActiveStorage::Blob,
        byte_size: file.size,
        filename: ActiveStorage::Filename.new('sample.jpg'),
        attachments: instance_double(ActiveRecord::Associations::CollectionProxy, exists?: false)
      )
      allow(blob).to receive(:open).and_yield(file)
      allow(described_class).to receive(:find_upload_blob!).with('signed-blob', account_id: 1).and_return(blob)
      expect(HTTParty).not_to receive(:post)

      expect do
        service.upload_blob(blob_signed_id: 'signed-blob', media_type: 'image')
      end.to raise_error(ArgumentError, 'Unsupported image file type: application/octet-stream')
    ensure
      file&.close!
    end

    it 'rejects a signed blob purpose from another account' do
      allow(described_class).to receive(:find_upload_blob!).with('foreign-blob', account_id: 1).and_raise(
        described_class::BlobReferenceRejectedError,
        'Uploaded media file is invalid or no longer available'
      )

      expect do
        service.upload_blob(blob_signed_id: 'foreign-blob', media_type: 'image')
      end.to raise_error(ArgumentError, 'Uploaded media file is invalid or no longer available')
    end

    it 'rejects an invalid or expired signed blob id' do
      allow(described_class).to receive(:find_upload_blob!).with('expired-blob', account_id: 1).and_raise(
        described_class::BlobReferenceUnavailableError,
        'Uploaded media file is invalid or no longer available'
      )

      expect do
        service.upload_blob(blob_signed_id: 'expired-blob', media_type: 'image')
      end.to raise_error(ArgumentError, 'Uploaded media file is invalid or no longer available')
    end

    it 'rejects blobs larger than the Meta upload limit before opening them' do
      blob = instance_double(
        ActiveStorage::Blob,
        byte_size: described_class::MAX_DOWNLOAD_SIZE + 1,
        attachments: instance_double(ActiveRecord::Associations::CollectionProxy, exists?: false)
      )
      allow(described_class).to receive(:find_upload_blob!).with('large-blob', account_id: 1).and_return(blob)
      expect(blob).not_to receive(:open)

      expect do
        service.upload_blob(blob_signed_id: 'large-blob', media_type: 'video')
      end.to raise_error(ArgumentError, 'Uploaded media file is too large')
    end
  end
end
