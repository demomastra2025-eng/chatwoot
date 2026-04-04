require 'rails_helper'

RSpec.describe Whatsapp::TemplateAssetUploadService do
  let(:whatsapp_channel) { instance_double(Channel::Whatsapp, provider_config: provider_config) }
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
    allow(GlobalConfigService).to receive(:load).with('WHATSAPP_API_VERSION', 'v22.0').and_return('v22.0')
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
  end
end
