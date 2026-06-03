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
          expect(firecrawl_service).to receive(:crawl) do |url, callback_url, limit, options|
            expect(url).to eq(document.external_link)
            expect(callback_url).to start_with("#{webhook_url}?assistant_id=#{assistant_id}&document_id=#{document.id}&token=")
            expect(callback_url.split('token=').last).to be_present
            expect(limit).to eq(20)
            expect(options).to be_a(Hash)
            double(parsed_response: { 'id' => 'crawl-job-1' })
          end

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

          expect(firecrawl_service).to receive(:crawl) do |url, callback_url, limit, options|
            expect(url).to eq(document.external_link)
            expect(callback_url).to start_with("#{webhook_url}?assistant_id=#{assistant_id}&document_id=#{document.id}&token=")
            expect(callback_url.split('token=').last).to be_present
            expect(limit).to eq(20)
            expect(options).to include(change_tracking: true, change_tracking_tag: "captain-document-#{document.id}")
            double(parsed_response: { 'id' => 'crawl-job-1' })
          end

          described_class.perform_now(document)
        end
      end

      context 'when crawl limit exceeds maximum' do
        before do
          allow(account).to receive(:usage_limits).and_return({ captain: { documents: { current_available: 1000 } } })
        end

        it 'caps the crawl limit at 500' do
          expect(firecrawl_service).to receive(:crawl) do |url, callback_url, limit, options|
            expect(url).to eq(document.external_link)
            expect(callback_url).to start_with("#{webhook_url}?assistant_id=#{assistant_id}&document_id=#{document.id}&token=")
            expect(callback_url.split('token=').last).to be_present
            expect(limit).to eq(500)
            expect(options).to be_a(Hash)
            double(parsed_response: { 'id' => 'crawl-job-1' })
          end

          described_class.perform_now(document)
        end
      end

      context 'with no usage limits configured' do
        before do
          allow(account).to receive(:usage_limits).and_return({})
        end

        it 'uses default crawl limit of 10' do
          expect(firecrawl_service).to receive(:crawl) do |url, callback_url, limit, options|
            expect(url).to eq(document.external_link)
            expect(callback_url).to start_with("#{webhook_url}?assistant_id=#{assistant_id}&document_id=#{document.id}&token=")
            expect(callback_url.split('token=').last).to be_present
            expect(limit).to eq(10)
            expect(options).to be_a(Hash)
            double(parsed_response: { 'id' => 'crawl-job-1' })
          end

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
        expect(firecrawl_service).to receive(:batch_scrape) do |urls, callback_url, options|
          expect(urls).to eq(['https://example.com/page-1', 'https://example.com/page-2'])
          expect(callback_url).to start_with("#{webhook_url}?assistant_id=#{assistant_id}&document_id=#{document.id}&token=")
          expect(callback_url.split('token=').last).to be_present
          expect(options).to be_a(Hash)
          double(parsed_response: { 'id' => 'batch-job-1' })
        end

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
        expect(file_document.source_text).to eq('## Q1 report')
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
        allow(firecrawl_service).to receive(:parse_upload).and_return(
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

      it 'uses Firecrawl parse upload and stores markdown content' do
        described_class.perform_now(file_document)

        expect(firecrawl_service).to have_received(:parse_upload).with(
          file_document.source_file,
          hash_including(only_main_content: true)
        )
        expect(file_document.reload).to be_available
        expect(file_document.name).to eq('Uploaded report')
        expect(file_document.source_text).to eq('## Uploaded report')
        expect(file_document.content).to eq('## Uploaded report')
        expect(file_document.metadata.dig('source_text', 'provider')).to eq('firecrawl')
        expect(file_document.metadata.dig('firecrawl', 'operation')).to eq('parse')
      end
    end

    context 'when importing an uploaded image' do
      let(:image_document) do
        build(:captain_document, assistant: document.assistant, account: document.account, external_link: nil).tap do |doc|
          doc.source_file.attach(
            io: File.open(Rails.root.join('spec/assets/avatar.png'), 'rb'),
            filename: 'avatar.png',
            content_type: 'image/png'
          )
          doc.save!
        end
      end

      it 'marks image uploads completed without source text parsing' do
        described_class.perform_now(image_document)

        expect(image_document.reload).to be_available
        expect(image_document.sync_status).to eq('completed')
        expect(image_document.metadata.dig('source_text', 'status')).to eq('skipped')
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
              account_id: document.account_id,
              page_link: link,
              source_document_id: document.id
            )
        end

        # Should also crawl the original link
        expect(Captain::Tools::SimplePageCrawlParserJob)
          .to receive(:perform_later)
          .with(
            assistant_id: assistant_id,
            account_id: document.account_id,
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

    context 'when importing fallback-supported files without Firecrawl' do
      before do
        allow(Captain::Tools::FirecrawlService).to receive(:configured?).and_return(false)
      end

      it 'extracts remote text file URLs with SafeFetch' do
        file_document = create(
          :captain_document,
          assistant: document.assistant,
          account: document.account,
          external_link: 'https://example.com/files/policy.txt',
          metadata: { 'firecrawl' => { 'mode' => 'file_url', 'sync' => {} } }
        )
        tempfile = Tempfile.new(['policy', '.txt'])
        tempfile.write('Workspace policy text')
        tempfile.rewind

        allow(SafeFetch).to receive(:fetch).and_yield(double(tempfile: tempfile, content_type: 'text/plain'))

        described_class.perform_now(file_document)

        expect(SafeFetch).to have_received(:fetch).with(
          file_document.external_link,
          hash_including(max_bytes: Llm::RuntimePolicy.web_document_parse_max_file_bytes)
        )
        expect(file_document.reload).to be_available
        expect(file_document.source_text).to eq('Workspace policy text')
        expect(file_document.metadata.dig('source_text', 'provider')).to eq('safe_fetch')
      ensure
        tempfile&.close!
      end

      it 'extracts uploaded text files without Firecrawl' do
        file_document = build(:captain_document, assistant: document.assistant, account: document.account, external_link: nil)
        file_document.source_file.attach(
          io: StringIO.new('Uploaded policy text'),
          filename: 'policy.txt',
          content_type: 'text/plain'
        )
        file_document.save!

        described_class.perform_now(file_document)

        expect(file_document.reload).to be_available
        expect(file_document.source_text).to eq('Uploaded policy text')
        expect(file_document.metadata.dig('source_text', 'provider')).to eq('attachment')
      end

      it 'extracts remote office file URLs without Firecrawl' do
        file_document = create(
          :captain_document,
          assistant: document.assistant,
          account: document.account,
          external_link: 'https://example.com/files/report.xlsx',
          metadata: { 'firecrawl' => { 'mode' => 'file_url', 'sync' => {} } }
        )
        tempfile = Tempfile.new(['report', '.xlsx'])
        allow(Captain::Documents::SourceTextExtractor)
          .to receive(:extract_text_from_tempfile)
          .and_return('Spreadsheet policy text')
        allow(SafeFetch).to receive(:fetch) do |url, options, &block|
          expect(url).to eq(file_document.external_link)
          expect(options[:allowed_content_types]).to include(
            'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'
          )
          block.call(
            double(
              tempfile: tempfile,
              content_type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'
            )
          )
        end

        described_class.perform_now(file_document)

        expect(file_document.reload).to be_available
        expect(file_document.source_text).to eq('Spreadsheet policy text')
        expect(file_document.metadata.dig('source_text', 'provider')).to eq('safe_fetch')
      ensure
        tempfile&.close!
      end

      it 'extracts uploaded office files without Firecrawl' do
        file_document = build(:captain_document, assistant: document.assistant, account: document.account, external_link: nil)
        file_document.source_file.attach(
          io: StringIO.new('Spreadsheet content'),
          filename: 'report.xlsx',
          content_type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'
        )
        file_document.save!
        allow(Captain::Documents::SourceTextExtractor)
          .to receive(:extract_text_from_tempfile)
          .and_return('Uploaded spreadsheet text')

        described_class.perform_now(file_document)

        expect(file_document.reload).to be_available
        expect(file_document.source_text).to eq('Uploaded spreadsheet text')
        expect(file_document.metadata.dig('source_text', 'provider')).to eq('attachment')
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
        allow(Captain::Tools::FirecrawlService).to receive(:configured?).and_return(false)
        pdf_service = instance_double(Captain::Llm::PdfProcessingService)
        expect(Captain::Llm::PdfProcessingService).to receive(:new).with(pdf_document).and_return(pdf_service)
        expect(pdf_service).to receive(:process)
        expect(pdf_document).to receive(:update!).with(status: :available)

        described_class.perform_now(pdf_document)
      end

      it 'handles PDF processing errors' do
        allow(Captain::Tools::FirecrawlService).to receive(:configured?).and_return(false)
        allow(Captain::Llm::PdfProcessingService).to receive(:new).and_raise(StandardError, 'Processing failed')

        expect { described_class.perform_now(pdf_document) }.to raise_error(StandardError, 'Processing failed')
      end
    end
  end
end
