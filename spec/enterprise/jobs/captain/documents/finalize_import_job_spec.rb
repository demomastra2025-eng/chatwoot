require 'rails_helper'

RSpec.describe Captain::Documents::FinalizeImportJob, type: :job do
  describe '#perform' do
    let(:import_run_id) { SecureRandom.uuid }
    let(:job_id) { 'job-123' }
    let(:page_url) { 'https://example.com/page' }
    let(:document) do
      create(
        :captain_document,
        metadata: {
          'firecrawl' => {
            'mode' => 'selected_pages',
            'job_id' => job_id,
            'sync' => {
              'status' => 'processing',
              'import_run_id' => import_run_id,
              'pages_total' => 1,
              'received_urls' => [page_url],
              'processed_urls' => [page_url]
            }
          }
        }
      )
    end

    it 'stores provider failed URLs before atomically completing the import' do
      failed_url = 'https://example.com/fail'
      document.update!(
        metadata: document.metadata.deep_merge(
          'firecrawl' => { 'sync' => { 'pages_total' => 2 } }
        )
      )
      firecrawl_service = instance_double(Captain::Tools::FirecrawlService)
      allow(Captain::Tools::FirecrawlService).to receive(:configured?).and_return(true)
      allow(Captain::Tools::FirecrawlService).to receive(:new).and_return(firecrawl_service)
      allow(firecrawl_service).to receive(:failed_urls_for_job).and_return([failed_url])

      described_class.perform_now(
        document_id: document.id,
        event_type: 'batch_scrape.completed',
        job_id: job_id,
        import_run_id: import_run_id
      )

      expect(document.reload.sync_status).to eq('completed')
      expect(document.failed_urls).to eq([failed_url])
      expect(document).to be_available
    end

    it 'retries when a page event never arrived' do
      document.update!(
        metadata: document.metadata.deep_merge(
          'firecrawl' => { 'sync' => { 'pages_total' => 2 } }
        )
      )
      allow(Captain::Tools::FirecrawlService).to receive(:configured?).and_return(false)
      scheduled_job = class_double(described_class)
      allow(described_class).to receive(:set).with(wait: 5.seconds).and_return(scheduled_job)

      expect(scheduled_job).to receive(:perform_later).with(
        document_id: document.id,
        event_type: 'batch_scrape.completed',
        job_id: job_id,
        error_message: nil,
        import_run_id: import_run_id,
        attempt: 1
      )

      described_class.perform_now(
        document_id: document.id,
        event_type: 'batch_scrape.completed',
        job_id: job_id,
        import_run_id: import_run_id
      )

      expect(document.reload.sync_status).to eq('processing')
    end

    it 'fails after the pending-page retry limit' do
      document.update!(
        metadata: document.metadata.deep_merge(
          'firecrawl' => { 'sync' => { 'pages_total' => 2 } }
        )
      )
      allow(Captain::Tools::FirecrawlService).to receive(:configured?).and_return(false)

      described_class.perform_now(
        document_id: document.id,
        event_type: 'batch_scrape.completed',
        job_id: job_id,
        import_run_id: import_run_id,
        attempt: described_class::MAX_PENDING_ATTEMPTS
      )

      expect(document.reload).to be_failed
      expect(document.sync_status).to eq('failed')
      expect(document.firecrawl_sync['last_error']).to eq('Firecrawl page processing timed out')
    end

    it 'gives an unknown-total empty crawl a bounded grace window' do
      document.update!(
        metadata: document.metadata.deep_merge(
          'firecrawl' => {
            'sync' => {
              'pages_total' => nil,
              'received_urls' => [],
              'processed_urls' => []
            }
          }
        )
      )
      allow(Captain::Tools::FirecrawlService).to receive(:configured?).and_return(false)
      scheduled_job = class_double(described_class)
      allow(described_class).to receive(:set).with(wait: 5.seconds).and_return(scheduled_job)

      expect(scheduled_job).to receive(:perform_later).with(
        document_id: document.id,
        event_type: 'crawl.completed',
        job_id: job_id,
        error_message: nil,
        import_run_id: import_run_id,
        attempt: 1
      )

      described_class.perform_now(
        document_id: document.id,
        event_type: 'crawl.completed',
        job_id: job_id,
        import_run_id: import_run_id
      )

      expect(document.reload).to be_in_progress
      expect(document.sync_status).to eq('processing')
    end

    it 'keeps the first failed terminal state when completed arrives later' do
      allow(Captain::Tools::FirecrawlService).to receive(:configured?).and_return(false)
      described_class.perform_now(
        document_id: document.id,
        event_type: 'crawl.failed',
        job_id: job_id,
        error_message: 'provider failed',
        import_run_id: import_run_id
      )

      described_class.perform_now(
        document_id: document.id,
        event_type: 'crawl.completed',
        job_id: job_id,
        import_run_id: import_run_id
      )

      expect(document.reload).to be_failed
      expect(document.sync_status).to eq('failed')
      expect(document.firecrawl_sync['last_error']).to eq('provider failed')
    end

    it 'ignores a stale import run' do
      new_run_id = SecureRandom.uuid
      document.update!(
        metadata: document.metadata.deep_merge(
          'firecrawl' => { 'sync' => { 'import_run_id' => new_run_id } }
        )
      )
      expect(Captain::Tools::FirecrawlService).not_to receive(:new)

      described_class.perform_now(
        document_id: document.id,
        event_type: 'batch_scrape.completed',
        job_id: job_id,
        import_run_id: import_run_id
      )

      expect(document.reload.sync_status).to eq('processing')
      expect(document.current_import_run_id).to eq(new_run_id)
    end

    it 'ignores a terminal event from another Firecrawl job' do
      expect(Captain::Tools::FirecrawlService).not_to receive(:new)

      described_class.perform_now(
        document_id: document.id,
        event_type: 'batch_scrape.completed',
        job_id: 'other-job',
        import_run_id: import_run_id
      )

      expect(document.reload.sync_status).to eq('processing')
    end

    it 'ignores a terminal event missing the bound Firecrawl job id' do
      expect(Captain::Tools::FirecrawlService).not_to receive(:new)

      described_class.perform_now(
        document_id: document.id,
        event_type: 'batch_scrape.completed',
        import_run_id: import_run_id
      )

      expect(document.reload.sync_status).to eq('processing')
    end

    it 'marks a failed terminal event with the provider error' do
      allow(Captain::Tools::FirecrawlService).to receive(:configured?).and_return(false)

      described_class.perform_now(
        document_id: document.id,
        event_type: 'crawl.failed',
        job_id: job_id,
        error_message: 'provider failed',
        import_run_id: import_run_id
      )

      expect(document.reload).to be_failed
      expect(document.sync_status).to eq('failed')
      expect(document.firecrawl_sync['last_error']).to eq('provider failed')
    end
  end
end
