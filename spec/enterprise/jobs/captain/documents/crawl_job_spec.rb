require 'rails_helper'

RSpec.describe Captain::Documents::CrawlJob, type: :job do
  let(:document) { create(:captain_document, external_link: 'https://example.com/page') }
  let(:assistant_id) { document.assistant_id }
  let(:webhook_url) { Rails.application.routes.url_helpers.enterprise_webhooks_firecrawl_url }

  describe '#perform' do
    context 'when Firecrawl is configured' do
      let(:firecrawl_service) { instance_double(Captain::Tools::FirecrawlService) }
      let(:account) { document.account }
      let(:token) { Digest::SHA256.hexdigest("-key#{document.assistant_id}#{document.account_id}") }

      before do
        allow(Captain::Tools::FirecrawlService).to receive(:new).and_return(firecrawl_service)
        allow(firecrawl_service).to receive(:crawl).and_return(double(parsed_response: { 'id' => 'crawl-job-1' }))
        allow(Captain::Tools::FirecrawlService).to receive(:configured?).and_return(true)
      end

      context 'with account usage limits' do
        before do
          allow(account).to receive(:usage_limits).and_return({ captain: { documents: { current_available: 20 } } })
        end

        it 'uses FirecrawlService with the correct crawl limit' do
          expect(firecrawl_service).to receive(:crawl).with(
            document.external_link,
            "#{webhook_url}?assistant_id=#{assistant_id}&document_id=#{document.id}&token=#{token}",
            20,
            anything
          )

          described_class.perform_now(document)
        end

        it 'passes change tracking options on delta refresh' do
          document.update!(
            metadata: {
              'firecrawl' => {
                'mode' => 'site_import',
                'sync' => { 'refresh_mode' => 'delta' }
              }
            }
          )

          expect(firecrawl_service).to receive(:crawl).with(
            document.external_link,
            "#{webhook_url}?assistant_id=#{assistant_id}&document_id=#{document.id}&token=#{token}",
            20,
            hash_including(change_tracking: true, change_tracking_tag: "captain-document-#{document.id}")
          )

          described_class.perform_now(document)
        end
      end

      context 'when crawl limit exceeds maximum' do
        before do
          allow(account).to receive(:usage_limits).and_return({ captain: { documents: { current_available: 1000 } } })
        end

        it 'caps the crawl limit at 500' do
          expect(firecrawl_service).to receive(:crawl).with(
            document.external_link,
            "#{webhook_url}?assistant_id=#{assistant_id}&document_id=#{document.id}&token=#{token}",
            500,
            anything
          )

          described_class.perform_now(document)
        end
      end

      context 'with no usage limits configured' do
        before do
          allow(account).to receive(:usage_limits).and_return({})
        end

        it 'uses default crawl limit of 10' do
          expect(firecrawl_service).to receive(:crawl).with(
            document.external_link,
            "#{webhook_url}?assistant_id=#{assistant_id}&document_id=#{document.id}&token=#{token}",
            10,
            anything
          )

          described_class.perform_now(document)
        end
      end
    end

    context 'when retrying failed urls' do
      let(:firecrawl_service) { instance_double(Captain::Tools::FirecrawlService) }
      let(:token) { Digest::SHA256.hexdigest("-key#{document.assistant_id}#{document.account_id}") }

      before do
        document.update!(
          metadata: {
            'firecrawl' => {
              'mode' => 'selected_pages',
              'sync' => {
                'refresh_mode' => 'retry_failed',
                'failed_urls' => ['https://example.com/page-1', 'https://example.com/page-2']
              }
            }
          }
        )
        allow(Captain::Tools::FirecrawlService).to receive(:new).and_return(firecrawl_service)
        allow(Captain::Tools::FirecrawlService).to receive(:configured?).and_return(true)
        allow(firecrawl_service).to receive(:batch_scrape).and_return(double(parsed_response: { 'id' => 'batch-job-1' }))
      end

      it 'uses batch scrape for failed urls' do
        expect(firecrawl_service).to receive(:batch_scrape).with(
          ['https://example.com/page-1', 'https://example.com/page-2'],
          "#{webhook_url}?assistant_id=#{assistant_id}&document_id=#{document.id}&token=#{token}",
          anything
        )

        described_class.perform_now(document)
      end
    end

    context 'when importing a remote supported file url' do
      let(:firecrawl_service) { instance_double(Captain::Tools::FirecrawlService) }
      let(:file_document) do
        create(
          :captain_document,
          assistant: document.assistant,
          account: document.account,
          external_link: 'https://example.com/files/report.xlsx',
          metadata: {
            'firecrawl' => {
              'mode' => 'file_url',
              'sync' => {}
            }
          }
        )
      end

      before do
        allow(Captain::Tools::FirecrawlService).to receive(:new).and_return(firecrawl_service)
        allow(Captain::Tools::FirecrawlService).to receive(:configured?).and_return(true)
        allow(firecrawl_service).to receive(:scrape).and_return(
          double(
            parsed_response: {
              'data' => {
                'markdown' => '## Q1 report',
                'metadata' => { 'title' => 'Q1 report' }
              }
            }
          )
        )
      end

      it 'uses Firecrawl scrape and stores markdown content' do
        described_class.perform_now(file_document)

        expect(firecrawl_service).to have_received(:scrape).with(
          file_document.external_link,
          hash_including(only_main_content: true)
        )
        expect(file_document.reload).to be_available
        expect(file_document.name).to eq('Q1 report')
        expect(file_document.content).to eq('## Q1 report')
      end
    end

    context 'when importing an uploaded supported file' do
      let(:firecrawl_service) { instance_double(Captain::Tools::FirecrawlService) }
      let(:file_document) do
        build(
          :captain_document,
          assistant: document.assistant,
          account: document.account,
          external_link: nil
        ).tap do |doc|
          doc.source_file.attach(
            io: StringIO.new('Spreadsheet content'),
            filename: 'report.xlsx',
            content_type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'
          )
          doc.save!
        end
      end

      before do
        allow(Captain::Tools::FirecrawlService).to receive(:new).and_return(firecrawl_service)
        allow(Captain::Tools::FirecrawlService).to receive(:configured?).and_return(true)
        allow(file_document).to receive(:display_url).and_return('https://storage.example.com/report.xlsx')
        allow(firecrawl_service).to receive(:scrape).and_return(
          double(
            parsed_response: {
              'data' => {
                'markdown' => '## Uploaded report',
                'metadata' => { 'title' => 'Uploaded report' }
              }
            }
          )
        )
      end

      it 'uses Firecrawl scrape against the uploaded file url and stores markdown content' do
        described_class.perform_now(file_document)

        expect(firecrawl_service).to have_received(:scrape).with(
          'https://storage.example.com/report.xlsx',
          hash_including(only_main_content: true)
        )
        expect(file_document.reload).to be_available
        expect(file_document.name).to eq('Uploaded report')
        expect(file_document.content).to eq('## Uploaded report')
      end
    end

    context 'when Firecrawl is not configured' do
      let(:page_links) { ['https://example.com/page1', 'https://example.com/page2'] }
      let(:simple_crawler) { instance_double(Captain::Tools::SimplePageCrawlService) }

      before do
        allow(Captain::Tools::FirecrawlService).to receive(:configured?).and_return(false)
        allow(Captain::Tools::SimplePageCrawlService)
          .to receive(:new)
          .with(document.external_link)
          .and_return(simple_crawler)

        allow(simple_crawler).to receive(:page_links).and_return(page_links)
      end

      it 'enqueues SimplePageCrawlParserJob for each discovered link' do
        page_links.each do |link|
          expect(Captain::Tools::SimplePageCrawlParserJob)
            .to receive(:perform_later)
            .with(
              assistant_id: assistant_id,
              page_link: link,
              source_document_id: document.id
            )
        end

        # Should also crawl the original link
        expect(Captain::Tools::SimplePageCrawlParserJob)
          .to receive(:perform_later)
          .with(
            assistant_id: assistant_id,
            page_link: document.external_link,
            source_document_id: document.id
          )

        described_class.perform_now(document)
      end

      it 'uses SimplePageCrawlService to discover page links' do
        expect(simple_crawler).to receive(:page_links)
        described_class.perform_now(document)
      end
    end

    context 'when document is a PDF' do
      let(:pdf_document) do
        build(
          :captain_document,
          assistant: document.assistant,
          account: document.account,
          external_link: nil
        ).tap do |doc|
          doc.pdf_file.attach(
            io: StringIO.new('PDF content'),
            filename: 'sample.pdf',
            content_type: 'application/pdf'
          )
          doc.save!
        end
      end

      it 'processes PDF using PdfProcessingService' do
        pdf_service = instance_double(Captain::Llm::PdfProcessingService)
        expect(Captain::Llm::PdfProcessingService).to receive(:new).with(pdf_document).and_return(pdf_service)
        expect(pdf_service).to receive(:process)
        expect(pdf_document).to receive(:update!).with(status: :available)

        described_class.perform_now(pdf_document)
      end

      it 'handles PDF processing errors' do
        allow(Captain::Llm::PdfProcessingService).to receive(:new).and_raise(StandardError, 'Processing failed')

        expect { described_class.perform_now(pdf_document) }.to raise_error(StandardError, 'Processing failed')
      end
    end
  end
end
