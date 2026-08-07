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

  describe '#upload' do
    it 'blocks localhost sample media urls before downloading' do
      expect(Down::NetHttp).not_to receive(:download)

      expect do
        service.upload(url: 'http://localhost:3000/sample.jpg', media_type: 'image')
      end.to raise_error(ArgumentError, 'Sample media URL cannot use localhost or local hostnames')
    end

    it 'blocks hosts that resolve to private addresses' do
      allow(Resolv).to receive(:getaddresses).with('assets.example.com').and_return(['127.0.0.1'])
      expect(Down::NetHttp).not_to receive(:download)

      expect do
        service.upload(url: 'https://assets.example.com/sample.jpg', media_type: 'image')
      end.to raise_error(ArgumentError, 'Sample media URL cannot resolve to a private IP address')
    end

    it 'blocks non-http urls' do
      expect(Down::NetHttp).not_to receive(:download)

      expect do
        service.upload(url: 'file:///tmp/sample.jpg', media_type: 'image')
      end.to raise_error(ArgumentError, 'Sample media URL must start with http:// or https://')
    end

    it 'uploads a public image using a non-redirecting download' do
      allow(Resolv).to receive(:getaddresses).with('cdn.example.com').and_return(['93.184.216.34'])

      file = Tempfile.new(['sample', '.jpg'])
      file.write('sample-image')
      file.rewind

      allow(Down::NetHttp).to receive(:download)
        .with('https://cdn.example.com/sample.jpg', max_size: described_class::MAX_DOWNLOAD_SIZE, max_redirects: 0)
        .and_return(file)
      allow(Marcel::MimeType).to receive(:for).with(file, name: 'sample.jpg').and_return('image/jpeg')

      upload_session_response = instance_double(HTTParty::Response, success?: true, parsed_response: { 'id' => 'upload-session-123' })
      upload_response = instance_double(HTTParty::Response, success?: true, parsed_response: { 'h' => 'uploaded-handle-123' })
      allow(HTTParty).to receive(:post).and_return(upload_session_response, upload_response)

      expect(service.upload(url: 'https://cdn.example.com/sample.jpg', media_type: 'image')).to eq('uploaded-handle-123')
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
        metadata: { 'account_id' => 1 }
      )
      allow(blob).to receive(:open).and_yield(file)
      allow(ActiveStorage::Blob).to receive(:find_signed).with('signed-blob').and_return(blob)
      allow(Marcel::MimeType).to receive(:for).with(file, name: 'invoice.pdf').and_return('application/pdf')

      upload_session_response = instance_double(HTTParty::Response, success?: true, parsed_response: { 'id' => 'upload-session-123' })
      upload_response = instance_double(HTTParty::Response, success?: true, parsed_response: { 'h' => 'uploaded-handle-123' })
      allow(HTTParty).to receive(:post).and_return(upload_session_response, upload_response)

      expect(service.upload_blob(blob_signed_id: 'signed-blob', media_type: 'document')).to eq('uploaded-handle-123')
    ensure
      file&.close!
    end

    it 'rejects a blob from another account' do
      blob = instance_double(
        ActiveStorage::Blob,
        byte_size: 10,
        metadata: { 'account_id' => 2 }
      )
      allow(ActiveStorage::Blob).to receive(:find_signed).with('foreign-blob').and_return(blob)

      expect do
        service.upload_blob(blob_signed_id: 'foreign-blob', media_type: 'image')
      end.to raise_error(ArgumentError, 'Uploaded media file does not belong to this account')
    end

    it 'rejects an invalid or expired signed blob id' do
      allow(ActiveStorage::Blob).to receive(:find_signed).with('expired-blob').and_return(nil)

      expect do
        service.upload_blob(blob_signed_id: 'expired-blob', media_type: 'image')
      end.to raise_error(ArgumentError, 'Uploaded media file is invalid or no longer available')
    end

    it 'rejects blobs larger than the Meta upload limit before opening them' do
      blob = instance_double(
        ActiveStorage::Blob,
        byte_size: described_class::MAX_DOWNLOAD_SIZE + 1,
        metadata: { 'account_id' => 1 }
      )
      allow(ActiveStorage::Blob).to receive(:find_signed).with('large-blob').and_return(blob)
      expect(blob).not_to receive(:open)

      expect do
        service.upload_blob(blob_signed_id: 'large-blob', media_type: 'video')
      end.to raise_error(ArgumentError, 'Uploaded media file is too large')
    end
  end
end
