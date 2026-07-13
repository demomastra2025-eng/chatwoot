require 'rails_helper'

RSpec.describe Captain::Tools::FirecrawlService do
  let(:api_key) { 'test-api-key' }
  let(:url) { 'https://example.com' }
  let(:webhook_url) { 'https://webhook.example.com/callback' }
  let(:crawl_limit) { 15 }
  let(:default_api_url) { 'https://api.firecrawl.dev/v2' }

  before do
    upsert_installation_config('CAPTAIN_FIRECRAWL_API_KEY', api_key)
  end

  describe '#initialize' do
    context 'when API key is configured' do
      it 'initializes successfully' do
        expect { described_class.new }.not_to raise_error
      end
    end

    context 'when API key is missing' do
      before do
        InstallationConfig.find_by(name: 'CAPTAIN_FIRECRAWL_API_KEY').destroy
      end

      it 'raises an error' do
        expect { described_class.new }.to raise_error('Missing API key for Firecrawl Cloud')
      end
    end

    context 'when API key is nil' do
      before do
        InstallationConfig.find_by(name: 'CAPTAIN_FIRECRAWL_API_KEY').update(value: nil)
      end

      it 'raises an error' do
        expect { described_class.new }.to raise_error('Missing API key for Firecrawl Cloud')
      end
    end

    context 'when API key is empty' do
      before do
        InstallationConfig.find_by(name: 'CAPTAIN_FIRECRAWL_API_KEY').update(value: '')
      end

      it 'raises an error' do
        expect { described_class.new }.to raise_error('Missing API key for Firecrawl Cloud')
      end
    end

    context 'when FIRECRAWL_API_KEY is present in env' do
      around do |example|
        ClimateControl.modify FIRECRAWL_API_KEY: 'env-api-key' do
          example.run
        end
      end

      it 'prefers env API key over installation config' do
        expect(described_class.api_key).to eq('env-api-key')
      end
    end

    context 'with an unauthenticated self-hosted endpoint' do
      before do
        InstallationConfig.find_by(name: 'CAPTAIN_FIRECRAWL_API_KEY').destroy
      end

      it 'is configured and initializes without a cloud API key' do
        ClimateControl.modify FIRECRAWL_API_URL: 'https://firecrawl.internal.example/v2', FIRECRAWL_API_KEY: nil do
          expect(described_class).to be_configured
          expect(described_class).to be_self_hosted
          expect(described_class).not_to be_authentication_configured
          expect { described_class.new }.not_to raise_error
        end
      end

      it 'omits the Authorization header' do
        ClimateControl.modify FIRECRAWL_API_URL: 'https://firecrawl.internal.example/v2', FIRECRAWL_API_KEY: nil do
          stub_request(:post, 'https://firecrawl.internal.example/v2/crawl')
            .with { |request| request.headers['Authorization'].blank? }
            .to_return(status: 200, body: '{"status":"success"}')

          described_class.new.perform(url, webhook_url, crawl_limit)

          expect(WebMock).to have_requested(:post, 'https://firecrawl.internal.example/v2/crawl')
        end
      end
    end
  end

  describe '#perform' do
    let(:service) { described_class.new }
    let(:expected_payload) do
      {
        url: url,
        limit: crawl_limit,
        webhook: {
          url: webhook_url,
          events: %w[started page completed failed]
        },
        sitemap: 'include',
        crawlEntireDomain: false,
        allowSubdomains: false,
        ignoreQueryParameters: true,
        scrapeOptions: {
          formats: ['markdown'],
          onlyMainContent: true
        }
      }.to_json
    end

    let(:expected_headers) do
      {
        'Authorization' => "Bearer #{api_key}",
        'Content-Type' => 'application/json'
      }
    end

    context 'when the API call is successful' do
      before do
        stub_request(:post, "#{default_api_url}/crawl")
          .with(
            body: expected_payload,
            headers: expected_headers
          )
          .to_return(status: 200, body: '{"status": "success"}')
      end

      it 'makes a POST request with correct parameters' do
        service.perform(url, webhook_url, crawl_limit)

        expect(WebMock).to have_requested(:post, "#{default_api_url}/crawl")
          .with(
            body: expected_payload,
            headers: expected_headers
          )
      end

      it 'uses default crawl limit when not specified' do
        default_payload = expected_payload.gsub(crawl_limit.to_s, '10')

        stub_request(:post, "#{default_api_url}/crawl")
          .with(
            body: default_payload,
            headers: expected_headers
          )
          .to_return(status: 200, body: '{"status": "success"}')

        service.perform(url, webhook_url)

        expect(WebMock).to have_requested(:post, "#{default_api_url}/crawl")
          .with(
            body: default_payload,
            headers: expected_headers
          )
      end

      it 'uses FIRECRAWL_API_URL from env when present' do
        ClimateControl.modify FIRECRAWL_API_URL: 'https://minio.cloud.vconsult.kz/v2/' do
          env_service = described_class.new

          stub_request(:post, 'https://minio.cloud.vconsult.kz/v2/crawl')
            .with(body: expected_payload, headers: expected_headers)
            .to_return(status: 200, body: '{"status": "success"}')

          env_service.perform(url, webhook_url, crawl_limit)

          expect(WebMock).to have_requested(:post, 'https://minio.cloud.vconsult.kz/v2/crawl')
            .with(body: expected_payload, headers: expected_headers)
        end
      end
    end

    context 'when the API call fails' do
      before do
        stub_request(:post, "#{default_api_url}/crawl")
          .to_raise(StandardError.new('Connection failed'))
      end

      it 'raises an error with the failure message' do
        expect { service.perform(url, webhook_url, crawl_limit) }
          .to raise_error('Failed to crawl URL: Connection failed')
      end
    end

    context 'when the API returns an error response' do
      before do
        stub_request(:post, "#{default_api_url}/crawl")
          .to_return(status: 422, body: '{"error": "Invalid URL"}')
      end

      it 'makes the request but does not raise an error' do
        expect { service.perform(url, webhook_url, crawl_limit) }.not_to raise_error

        expect(WebMock).to have_requested(:post, "#{default_api_url}/crawl")
          .with(
            body: expected_payload,
            headers: expected_headers
          )
      end
    end
  end

  describe '#failed_urls_for_job' do
    let(:service) { described_class.new }

    it 'returns failed urls from batch scrape errors' do
      stub_request(:get, "#{default_api_url}/batch/scrape/job-123/errors")
        .with(headers: { 'Authorization' => "Bearer #{api_key}" })
        .to_return(
          status: 200,
          body: {
            errors: [{ url: 'https://example.com/fail-1' }],
            robotsBlocked: ['https://example.com/blocked']
          }.to_json
        )

      expect(service.failed_urls_for_job('job-123', 'selected_pages'))
        .to eq(['https://example.com/fail-1', 'https://example.com/blocked'])
    end
  end

  describe '#search' do
    let(:service) { described_class.new }

    it 'posts a v2 search payload with safe defaults and optional scrape settings' do
      stub_request(:post, "#{default_api_url}/search")
        .with(
          headers: {
            'Authorization' => "Bearer #{api_key}",
            'Content-Type' => 'application/json'
          }
        )
        .to_return(status: 200, body: { success: true, data: { web: [] } }.to_json)

      service.search(
        'openrouter structured outputs',
        limit: 3,
        sources: ['web'],
        include_domains: ['docs.firecrawl.dev'],
        scrape_results: true
      )

      expect(WebMock).to(
        have_requested(:post, "#{default_api_url}/search").with do |request|
          payload = JSON.parse(request.body)
          payload['query'] == 'openrouter structured outputs' &&
            payload['limit'] == 3 &&
            payload['sources'] == [{ 'type' => 'web' }] &&
            payload['includeDomains'] == ['docs.firecrawl.dev'] &&
            payload['ignoreInvalidURLs'] == true &&
            payload.dig('scrapeOptions', 'formats') == ['markdown'] &&
            payload.dig('scrapeOptions', 'onlyMainContent') == true
        end
      )
    end
  end

  describe '#parse_upload' do
    let(:service) { described_class.new }
    let(:blob) do
      ActiveStorage::Blob.create_and_upload!(
        io: StringIO.new('Spreadsheet content'),
        filename: 'report.xlsx',
        content_type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'
      )
    end

    it 'uploads the file to the Firecrawl parse endpoint as multipart form data' do
      stub_request(:post, "#{default_api_url}/parse")
        .to_return(status: 200, body: { success: true, data: { markdown: '## Report' } }.to_json)

      service.parse_upload(blob, only_main_content: false)

      expect(WebMock).to have_requested(:post, "#{default_api_url}/parse")
        .with(headers: { 'Authorization' => "Bearer #{api_key}" }) do |request|
          request.body.include?('name="file"') &&
            request.body.include?('name="options"') &&
            request.body.include?('"onlyMainContent":false')
        end
    end
  end
end
