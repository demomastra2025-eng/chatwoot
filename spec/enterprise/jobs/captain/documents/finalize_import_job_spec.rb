require 'rails_helper'

RSpec.describe Captain::Documents::FinalizeImportJob, type: :job do
  describe '#perform' do
    let(:document) do
      create(
        :captain_document,
        metadata: {
          'firecrawl' => {
            'mode' => 'selected_pages',
            'sync' => { 'status' => 'processing' }
          }
        }
      )
    end

    it 'stores failed urls and marks import completed' do
      firecrawl_service = instance_double(Captain::Tools::FirecrawlService)
      allow(Captain::Tools::FirecrawlService).to receive(:configured?).and_return(true)
      allow(Captain::Tools::FirecrawlService).to receive(:new).and_return(firecrawl_service)
      allow(firecrawl_service).to receive(:failed_urls_for_job).and_return(['https://example.com/fail'])

      described_class.perform_now(
        document_id: document.id,
        event_type: 'batch_scrape.completed',
        job_id: 'job-123'
      )

      expect(document.reload.sync_status).to eq('completed')
      expect(document.failed_urls).to eq(['https://example.com/fail'])
    end
  end
end
