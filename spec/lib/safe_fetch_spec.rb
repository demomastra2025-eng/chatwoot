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

    it 'follows safe redirects and yields the final response' do
      redirected_url = 'http://example.com/final-image.png'
      stub_request(:get, url).to_return(status: 302, headers: { 'Location' => redirected_url })
      stub_request(:get, redirected_url).to_return(
        status: 200,
        body: File.new(Rails.root.join('spec/assets/avatar.png')),
        headers: { 'Content-Type' => 'image/png' }
      )

      described_class.fetch(url) do |result|
        expect(result.filename).to eq('final-image.png')
        expect(result.content_type).to eq('image/png')
        expect(result.tempfile.size).to be_positive
      end
    end

    it 'strips sensitive headers and basic auth on cross-origin redirects' do
      redirected_url = 'http://cdn.example.com/final-image.png'
      allow(Resolv).to receive(:getaddresses).with('cdn.example.com').and_return(['93.184.216.35'])

      stub_request(:get, url).to_return(status: 302, headers: { 'Location' => redirected_url })
      stub_request(:get, redirected_url)
        .with do |request|
          request.headers['Authorization'].blank? && request.headers['X-Chatwoot-Delivery'] == 'delivery-1'
        end
        .to_return(
          status: 200,
          body: File.new(Rails.root.join('spec/assets/avatar.png')),
          headers: { 'Content-Type' => 'image/png' }
        )

      described_class.fetch(
        url,
        headers: { 'Authorization' => 'Bearer upstream-secret', 'X-Chatwoot-Delivery' => 'delivery-1' },
        http_basic_authentication: %w[user password]
      ) do |result|
        expect(result.filename).to eq('final-image.png')
      end
    end

    it 'rejects private IP literals' do
      expect { described_class.fetch('http://10.0.0.1/secret') { raise 'should not yield' } }
        .to raise_error(SafeFetch::UnsafeUrlError)
    end

    it 'rejects hostnames resolving to private IPs' do
      allow(Resolv).to receive(:getaddresses).with('evil.example.com').and_return(['10.0.0.1'])

      expect { described_class.fetch('http://evil.example.com/secret') { raise 'should not yield' } }
        .to raise_error(SafeFetch::UnsafeUrlError)
    end

    it 'allows explicit allowlisted private hosts for scoped webhook use cases' do
      private_url = 'http://internal-webhook.example.com/image.png'
      allow(Resolv).to receive(:getaddresses).with('internal-webhook.example.com').and_return(['10.0.0.5'])
      stub_request(:get, private_url).to_return(
        status: 200,
        body: File.new(Rails.root.join('spec/assets/avatar.png')),
        headers: { 'Content-Type' => 'image/png' }
      )

      described_class.fetch(private_url, private_network_allowed_hosts: ['internal-webhook.example.com']) do |result|
        expect(result.filename).to eq('image.png')
        expect(result.content_type).to eq('image/png')
      end
    end

    it 'rejects redirects to private hosts unless the redirect host is allowlisted' do
      private_url = 'http://internal-webhook.example.com/final-image.png'
      allow(Resolv).to receive(:getaddresses).with('internal-webhook.example.com').and_return(['10.0.0.5'])
      stub_request(:get, url).to_return(status: 302, headers: { 'Location' => private_url })

      expect { described_class.fetch(url) { raise 'should not yield' } }
        .to raise_error(SafeFetch::UnsafeUrlError)
    end

    it 'allows redirects to explicitly allowlisted private hosts' do
      private_url = 'http://internal-webhook.example.com/final-image.png'
      allow(Resolv).to receive(:getaddresses).with('internal-webhook.example.com').and_return(['10.0.0.5'])
      stub_request(:get, url).to_return(status: 302, headers: { 'Location' => private_url })
      stub_request(:get, private_url).to_return(
        status: 200,
        body: File.new(Rails.root.join('spec/assets/avatar.png')),
        headers: { 'Content-Type' => 'image/png' }
      )

      described_class.fetch(url, private_network_allowed_hosts: ['internal-webhook.example.com']) do |result|
        expect(result.filename).to eq('final-image.png')
      end
    end

    it 'keeps metadata and link-local addresses blocked even when listed' do
      metadata_url = 'http://169.254.169.254/latest/meta-data'

      expect { described_class.fetch(metadata_url, private_network_allowed_hosts: ['169.254.169.254']) { raise 'should not yield' } }
        .to raise_error(SafeFetch::UnsafeUrlError)
    end

    it 'rejects unsupported content types' do
      stub_request(:get, url).to_return(status: 200, body: '<html></html>', headers: { 'Content-Type' => 'text/html' })

      expect { described_class.fetch(url) { raise 'should not yield' } }
        .to raise_error(SafeFetch::UnsupportedContentTypeError)
    end

    it 'rejects files that exceed the configured size limit' do
      allow(GlobalConfigService).to receive(:load).with('MAXIMUM_FILE_UPLOAD_SIZE', 40).and_return('1')
      stub_request(:get, url).to_return(
        status: 200,
        body: 'x' * (1.megabyte + 1),
        headers: { 'Content-Type' => 'image/png' }
      )

      expect { described_class.fetch(url) { raise 'should not yield' } }
        .to raise_error(SafeFetch::FileTooLargeError)
    end

    it 'supports safe POST requests with JSON headers and no content-type validation' do
      webhook_url = 'http://example.com/webhook'
      body = { event: 'message_created' }.to_json

      stub_request(:post, webhook_url)
        .with(
          body: body,
          headers: {
            'Content-Type' => 'application/json',
            'Accept' => 'application/json',
            'X-Chatwoot-Delivery' => 'delivery-1'
          }
        )
        .to_return(status: 204, body: '', headers: {})

      expect do |probe|
        described_class.fetch(
          webhook_url,
          method: :post,
          body: body,
          headers: {
            'Content-Type' => 'application/json',
            'Accept' => 'application/json',
            'X-Chatwoot-Delivery' => 'delivery-1'
          },
          validate_content_type: false,
          &probe
        )
      end.to yield_control
    end

    it 'rejects unsupported HTTP methods' do
      expect { described_class.fetch(url, method: :trace) { nil } }
        .to raise_error(SafeFetch::UnsupportedMethodError)
    end
  end
end
