require 'rails_helper'

RSpec.describe SafeFetch do
  let(:url) { 'http://example.com/image.png' }

  before do
    allow(Resolv).to receive(:getaddresses).and_call_original
    allow(Resolv).to receive(:getaddresses).with('example.com').and_return(['93.184.216.34'])
  end

  describe '.fetch' do
    it 'yields a tempfile, filename, and content type for valid public URLs' do
      stub_request(:get, url).to_return(
        status: 200,
        body: File.new(Rails.root.join('spec/assets/avatar.png')),
        headers: { 'Content-Type' => 'image/png' }
      )

      described_class.fetch(url) do |result|
        expect(result.tempfile).to be_a(Tempfile)
        expect(result.filename).to eq('image.png')
        expect(result.content_type).to eq('image/png')
        expect(result.tempfile.size).to be_positive
      end
    end

    it 'rejects private IP literals' do
      expect { described_class.fetch('http://10.0.0.1/secret') { nil } }
        .to raise_error(SafeFetch::UnsafeUrlError)
    end

    it 'rejects hostnames resolving to private IPs' do
      allow(Resolv).to receive(:getaddresses).with('evil.example.com').and_return(['10.0.0.1'])

      expect { described_class.fetch('http://evil.example.com/secret') { nil } }
        .to raise_error(SafeFetch::UnsafeUrlError)
    end

    it 'rejects unsupported content types' do
      stub_request(:get, url).to_return(status: 200, body: '<html></html>', headers: { 'Content-Type' => 'text/html' })

      expect { described_class.fetch(url) { nil } }
        .to raise_error(SafeFetch::UnsupportedContentTypeError)
    end

    it 'rejects files that exceed the configured size limit' do
      allow(GlobalConfigService).to receive(:load).with('MAXIMUM_FILE_UPLOAD_SIZE', 40).and_return('1')
      stub_request(:get, url).to_return(
        status: 200,
        body: 'x' * (1.megabyte + 1),
        headers: { 'Content-Type' => 'image/png' }
      )

      expect { described_class.fetch(url) { nil } }
        .to raise_error(SafeFetch::FileTooLargeError)
    end
  end
end
