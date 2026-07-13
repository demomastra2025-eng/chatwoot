require 'rails_helper'

RSpec.describe Captain::Document, type: :model do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }

  describe 'FAQ generation settings' do
    it 'defaults FAQ generation to enabled' do
      expect(described_class.new.faq_generation_enabled).to be true
    end

    it 'uses source_text before preview content for FAQ generation' do
      document = build(:captain_document, source_text: 'Full extracted text', content: 'Preview text')

      expect(document.faq_generation_text).to eq('Full extracted text')
    end

    it 'marks available uploaded files as sendable' do
      document = build(:captain_document, assistant: assistant, account: account, status: :available, external_link: nil)
      document.source_file.attach(
        io: StringIO.new('Spreadsheet content'),
        filename: 'report.xlsx',
        content_type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'
      )
      document.save!

      expect(document).to be_sendable_file
      expect(document.sendable_filename).to eq('report.xlsx')
      expect(document.sendable_file_signed_id).to be_present
    end
  end

  describe 'URL normalization' do
    it 'removes a trailing slash before validation' do
      document = create(:captain_document,
                        assistant: assistant,
                        account: account,
                        external_link: 'https://example.com/path/')

      expect(document.external_link).to eq('https://example.com/path')
    end
  end

  describe 'workspace ownership' do
    it 'allows general workspace documents without an assistant' do
      document = build(:captain_document, account: account, assistant: nil, visibility: :general)

      expect(document).to be_valid
    end

    it 'allows workspace-personal documents without an assistant' do
      document = build(:captain_document, account: account, assistant: nil, visibility: :personal)

      expect(document).to be_valid
    end

    it 'keeps external links unique per account instead of per assistant' do
      create(:captain_document, account: account, assistant: assistant, external_link: 'https://example.com/shared')
      second_assistant = create(:captain_assistant, account: account)
      duplicate = build(:captain_document, account: account, assistant: second_assistant, external_link: 'https://example.com/shared')
      other_account_duplicate = build(:captain_document, account: create(:account), external_link: 'https://example.com/shared')

      expect(duplicate).not_to be_valid
      expect(other_account_duplicate).to be_valid
    end

    it 'returns general documents plus personal documents for the selected assistant' do
      general_document = create(:captain_document, account: account, assistant: nil, visibility: :general)
      workspace_personal_document = create(:captain_document, account: account, assistant: nil, visibility: :personal)
      personal_document = create(:captain_document, account: account, assistant: assistant, visibility: :personal)
      other_personal_document = create(
        :captain_document,
        account: account,
        assistant: create(:captain_assistant, account: account),
        visibility: :personal
      )

      expect(described_class.visible_to_assistant(assistant.id)).to include(
        general_document,
        workspace_personal_document,
        personal_document
      )
      expect(described_class.visible_to_assistant(assistant.id)).not_to include(other_personal_document)
    end

    it 'returns workspace-owned knowledge without an assistant filter' do
      general_document = create(:captain_document, account: account, assistant: nil, visibility: :general)
      workspace_personal_document = create(:captain_document, account: account, assistant: nil, visibility: :personal)
      assistant_personal_document = create(:captain_document, account: account, assistant: assistant, visibility: :personal)

      expect(described_class.visible_to_assistant(nil)).to include(general_document, workspace_personal_document)
      expect(described_class.visible_to_assistant(nil)).not_to include(assistant_personal_document)
    end
  end

  describe '#embedding_status_summary' do
    it 'summarizes chunk embedding health for operator visibility' do
      document = create(:captain_document, assistant: assistant, account: account)
      create(:captain_document_chunk, document: document, account: account, assistant: assistant, embedding_status: :indexed)
      create(:captain_document_chunk, document: document, account: account, assistant: assistant, embedding_status: :pending)
      create(:captain_document_chunk,
             document: document,
             account: account,
             assistant: assistant,
             embedding_status: :failed,
             embedding_error: 'provider unavailable',
             embedding_updated_at: 1.minute.ago)

      expect(document.embedding_status_summary).to include(
        total: 3,
        indexed: 1,
        pending: 1,
        failed: 1,
        stale: 0,
        degraded: true,
        last_error: 'provider unavailable'
      )
    end

    it 'returns a clean zero-count summary when no chunks exist yet' do
      document = create(:captain_document, assistant: assistant, account: account)

      expect(document.embedding_status_summary).to eq(
        total: 0,
        indexed: 0,
        pending: 0,
        failed: 0,
        stale: 0,
        degraded: false,
        last_error: nil
      )
    end
  end

  describe 'import lifecycle' do
    it 'does not complete a newer import run from a stale model instance' do
      old_run_id = SecureRandom.uuid
      new_run_id = SecureRandom.uuid
      document = create(
        :captain_document,
        account: account,
        assistant: assistant,
        metadata: { 'firecrawl' => { 'sync' => { 'import_run_id' => old_run_id, 'status' => 'processing' } } }
      )
      described_class.find(document.id).update!(
        metadata: { 'firecrawl' => { 'sync' => { 'import_run_id' => new_run_id, 'status' => 'queued' } } }
      )

      expect(document.mark_import_completed!(import_run_id: old_run_id)).to be false
      expect(document.reload).to be_in_progress
      expect(document.current_import_run_id).to eq(new_run_id)
      expect(document.sync_status).to eq('queued')
    end

    it 'creates one stable import run id when metadata has none' do
      document = create(:captain_document, account: account, assistant: assistant)

      first_run_id = document.ensure_import_run_id!
      second_run_id = document.ensure_import_run_id!

      expect(first_run_id).to be_present
      expect(second_run_id).to eq(first_run_id)
      expect(document.reload.current_import_run_id).to eq(first_run_id)
    end

    it 'tracks received, processed and failed pages until the declared total is resolved', :aggregate_failures do
      import_run_id = SecureRandom.uuid
      document = create(
        :captain_document,
        account: account,
        assistant: assistant,
        metadata: {
          'firecrawl' => {
            'job_id' => 'provider-job',
            'sync' => {
              'import_run_id' => import_run_id,
              'status' => 'processing',
              'pages_total' => 2
            }
          }
        }
      )

      expect(document.mark_page_received!('https://example.com/one/', import_run_id: import_run_id)).to be true
      expect(document.mark_page_processed!('https://example.com/one', import_run_id: import_run_id)).to be true
      expect(document.pending_import_pages?).to be true
      expect(document.record_failed_urls!(['https://example.com/two/'], import_run_id: import_run_id)).to be true
      expect(document.pending_import_pages?).to be false
      expect(document.finalize_import!(failed_urls: document.failed_urls, import_run_id: import_run_id)).to eq(:completed)

      document.reload
      expect(document.received_urls).to contain_exactly('https://example.com/one', 'https://example.com/two')
      expect(document.failed_urls).to eq(['https://example.com/two'])
      expect(document).to be_available
      expect(document.sync_status).to eq('completed')
    end

    it 'clears a previous known page total when a new crawl has an unknown total' do
      document = create(
        :captain_document,
        account: account,
        assistant: assistant,
        metadata: {
          'firecrawl' => {
            'mode' => 'site_import',
            'job_id' => 'old-job',
            'sync' => {
              'status' => 'completed',
              'pages_total' => 25,
              'pages_processed' => 25,
              'processed_urls' => ['https://example.com/old']
            }
          }
        }
      )

      document.prepare_for_resync!(refresh_mode: 'full')

      expect(document.reload.pages_total).to be_nil
      expect(document.pages_processed).to eq(0)
      expect(document.import_job_id).to be_nil
      expect(document.firecrawl_sync).not_to have_key('last_synced_at')
    end

    it 'starts retry_failed with a clean failure set and preserves retry targets' do
      document = create(
        :captain_document,
        account: account,
        assistant: assistant,
        metadata: {
          'firecrawl' => {
            'job_id' => 'old-job',
            'sync' => { 'failed_urls' => ['https://example.com/one', 'https://example.com/two'] }
          }
        }
      )

      document.prepare_for_resync!(refresh_mode: 'retry_failed')
      import_run_id = document.current_import_run_id

      expect(document.retry_urls).to contain_exactly('https://example.com/one', 'https://example.com/two')
      expect(document.failed_urls).to be_empty
      expect(document.pages_total).to eq(2)
      expect(document.import_job_id).to be_nil

      document.mark_page_processed!('https://example.com/one', import_run_id: import_run_id)
      document.mark_page_processed!('https://example.com/unexpected', import_run_id: import_run_id)
      expect(document.reload.pending_import_pages?).to be true
      expect(
        [document.expected_import_url?('https://example.com/two'), document.expected_import_url?('https://example.com/unexpected')]
      ).to eq([true, false])
      expect(document).to be_in_progress
    end

    it 'stores the provider response job id and rejects a conflicting id' do
      import_run_id = SecureRandom.uuid
      document = create(
        :captain_document,
        account: account,
        assistant: assistant,
        metadata: { 'firecrawl' => { 'sync' => { 'import_run_id' => import_run_id, 'status' => 'processing' } } }
      )

      document.mark_import_started!(job_id: 'provider-job', import_run_id: import_run_id)
      expect(document.reload.import_job_id).to eq('provider-job')
      expect do
        document.mark_import_started!(job_id: 'wrong-job', import_run_id: import_run_id)
      end.to raise_error(Captain::Document::ImportJobMismatchError)
      expect(document.reload.import_job_id).to eq('provider-job')
    end

    it 'merges failures recorded after a stale completion snapshot' do
      import_run_id = SecureRandom.uuid
      document = create(
        :captain_document,
        account: account,
        assistant: assistant,
        metadata: {
          'firecrawl' => {
            'job_id' => 'provider-job',
            'sync' => {
              'import_run_id' => import_run_id,
              'status' => 'processing',
              'pages_total' => 2,
              'processed_urls' => ['https://example.com/ok'],
              'received_urls' => ['https://example.com/ok']
            }
          }
        }
      )
      stale_snapshot = ['https://example.com/provider-failure']
      document.record_failed_urls!(['https://example.com/concurrent-failure'], import_run_id: import_run_id)

      expect(document.finalize_import!(failed_urls: stale_snapshot, import_run_id: import_run_id)).to eq(:completed)
      expect(document.reload.failed_urls).to contain_exactly(*stale_snapshot, 'https://example.com/concurrent-failure')
    end

    it 'ignores late started and page callbacks after completion' do
      import_run_id = SecureRandom.uuid
      document = create(
        :captain_document,
        account: account,
        assistant: assistant,
        metadata: { 'firecrawl' => { 'sync' => { 'import_run_id' => import_run_id, 'status' => 'processing' } } }
      )
      document.mark_import_completed!(import_run_id: import_run_id)
      terminal_sync = document.reload.firecrawl_sync.deep_dup
      original_name = document.name

      active_write_applied = document.with_active_import_run(import_run_id) { document.update!(name: 'Late parser write') }
      document.mark_import_processing!(import_run_id: import_run_id)
      document.mark_import_started!(job_id: 'late-job', pages_total: 10, import_run_id: import_run_id)
      document.mark_page_received!('https://example.com/late', import_run_id: import_run_id)
      document.mark_page_processed!('https://example.com/late', import_run_id: import_run_id)
      document.record_failed_urls!(['https://example.com/late-failure'], import_run_id: import_run_id)
      document.record_change_result!('https://example.com/late', 'changed', import_run_id: import_run_id)

      expect(active_write_applied).to be false
      expect(document.reload).to be_available
      expect(document.name).to eq(original_name)
      expect(document.sync_status).to eq('completed')
      expect(document.import_job_id).to be_nil
      expect(document.firecrawl_sync).to eq(terminal_sync)
    end

    it 'does not resurrect a failed terminal import with a completed event' do
      import_run_id = SecureRandom.uuid
      document = create(
        :captain_document,
        account: account,
        assistant: assistant,
        metadata: { 'firecrawl' => { 'sync' => { 'import_run_id' => import_run_id, 'status' => 'processing' } } }
      )

      document.mark_import_failed!('provider failed', import_run_id: import_run_id)

      expect(document.finalize_import!(import_run_id: import_run_id)).to eq(:terminal)
      expect(document.reload).to be_failed
      expect(document.sync_status).to eq('failed')
    end

    it 'does not time out an import whose final page resolved before the timeout lock' do
      import_run_id = SecureRandom.uuid
      document = create(
        :captain_document,
        account: account,
        assistant: assistant,
        metadata: {
          'firecrawl' => {
            'sync' => {
              'import_run_id' => import_run_id,
              'status' => 'processing',
              'pages_total' => 1
            }
          }
        }
      )
      document.mark_page_processed!('https://example.com/final', import_run_id: import_run_id)

      expect(document.fail_import_if_pending!('timeout', import_run_id: import_run_id)).to eq(:terminal)
      expect(document.reload).to be_available
      expect(document.sync_status).to eq('completed')
    end

    it 'rejects page mutations from a stale run' do
      import_run_id = SecureRandom.uuid
      document = create(
        :captain_document,
        account: account,
        assistant: assistant,
        metadata: { 'firecrawl' => { 'sync' => { 'import_run_id' => import_run_id, 'status' => 'processing' } } }
      )

      expect(document.mark_page_received!('https://example.com/stale', import_run_id: SecureRandom.uuid)).to be false
      expect(document.reload.received_urls).to be_empty
    end
  end

  describe 'PDF support' do
    let(:pdf_document) do
      doc = build(:captain_document, assistant: assistant, account: account)
      doc.pdf_file.attach(
        io: StringIO.new('PDF content'),
        filename: 'test.pdf',
        content_type: 'application/pdf'
      )
      doc
    end

    describe 'validations' do
      it 'allows PDF file without external link' do
        pdf_document.external_link = nil
        expect(pdf_document).to be_valid
      end

      it 'allows remote PDF urls without an uploaded file' do
        remote_pdf = build(:captain_document, assistant: assistant, account: account, external_link: 'https://example.com/file.pdf')
        expect(remote_pdf).to be_valid
      end

      it 'allows supported remote file urls in file url mode' do
        remote_file = build(
          :captain_document,
          assistant: assistant,
          account: account,
          external_link: 'https://example.com/report.xlsx',
          metadata: { 'firecrawl' => { 'mode' => 'file_url' } }
        )

        expect(remote_file).to be_valid
      end

      it 'rejects unsupported remote file urls in file url mode when an extension is present' do
        remote_file = build(
          :captain_document,
          assistant: assistant,
          account: account,
          external_link: 'https://example.com/report.exe',
          metadata: { 'firecrawl' => { 'mode' => 'file_url' } }
        )

        expect(remote_file).not_to be_valid
        expect(remote_file.errors[:external_link]).to include(I18n.t('captain.documents.remote_file_url_error'))
      end

      it 'validates PDF uploads against the account storage limit' do
        account.update!(limits: { storage_bytes: 10.megabytes })

        doc = build(:captain_document, assistant: assistant, account: account)
        doc.pdf_file.attach(
          io: StringIO.new('x' * 11.megabytes),
          filename: 'large.pdf',
          content_type: 'application/pdf'
        )
        doc.external_link = nil
        expect(doc).not_to be_valid
        expect(doc.errors[:pdf_file]).to include(AccountLimits::StorageUsageService::LIMIT_EXCEEDED_MESSAGE)
      end
    end

    describe '#pdf_document?' do
      it 'returns true for attached PDF' do
        expect(pdf_document.pdf_document?).to be true
      end

      it 'returns true for .pdf external links' do
        doc = build(:captain_document, external_link: 'https://example.com/document.pdf')
        expect(doc.pdf_document?).to be true
      end

      it 'returns false for non-PDF documents' do
        doc = build(:captain_document, external_link: 'https://example.com')
        expect(doc.pdf_document?).to be false
      end
    end

    describe '#remote_file_url?' do
      it 'returns true for supported office file urls' do
        doc = build(
          :captain_document,
          external_link: 'https://example.com/document.docx',
          metadata: { 'firecrawl' => { 'mode' => 'file_url' } }
        )

        expect(doc.remote_file_url?).to be true
      end

      it 'returns true for supported HTML file urls' do
        doc = build(
          :captain_document,
          external_link: 'https://example.com/document.html',
          metadata: { 'firecrawl' => { 'mode' => 'file_url' } }
        )

        expect(doc.remote_file_url?).to be true
      end

      it 'returns true for supported text file urls' do
        doc = build(
          :captain_document,
          external_link: 'https://example.com/document.txt',
          metadata: { 'firecrawl' => { 'mode' => 'file_url' } }
        )

        expect(doc.remote_file_url?).to be true
      end

      it 'returns false for unsupported file urls' do
        doc = build(
          :captain_document,
          external_link: 'https://example.com/document.exe',
          metadata: { 'firecrawl' => { 'mode' => 'file_url' } }
        )

        expect(doc.remote_file_url?).to be false
      end
    end

    describe '#display_url' do
      it 'returns Rails blob URL for attached PDFs' do
        pdf_document.save!
        # The display_url method calls rails_blob_url which returns a URL containing 'rails/active_storage'
        url = pdf_document.display_url
        expect(url).to be_present
      end

      it 'returns external_link for web documents' do
        doc = create(:captain_document, external_link: 'https://example.com')
        expect(doc.display_url).to eq('https://example.com')
      end
    end

    describe 'automatic external_link generation' do
      it 'generates unique external_link for PDFs' do
        pdf_document.external_link = nil
        pdf_document.save!

        expect(pdf_document.external_link).to start_with('PDF: test_')
      end
    end
  end

  describe 'file upload support' do
    let(:uploaded_file_document) do
      build(:captain_document, assistant: assistant, account: account).tap do |doc|
        doc.source_file.attach(
          io: StringIO.new('Spreadsheet content'),
          filename: 'report.xlsx',
          content_type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'
        )
      end
    end

    it 'allows supported uploaded office files without external link' do
      uploaded_file_document.external_link = nil

      expect(uploaded_file_document).to be_valid
    end

    it 'sets source mode to file_upload for uploaded office files' do
      expect(uploaded_file_document.source_mode).to eq('file_upload')
    end

    it 'allows supported uploaded text files without external link' do
      document = build(:captain_document, assistant: assistant, account: account)
      document.source_file.attach(
        io: StringIO.new('Text file content'),
        filename: 'notes.txt',
        content_type: 'text/plain'
      )
      document.external_link = nil

      expect(document).to be_valid
    end

    it 'rejects unsupported uploaded file types' do
      document = build(:captain_document, assistant: assistant, account: account)
      document.source_file.attach(
        io: StringIO.new('Binary file content'),
        filename: 'notes.exe',
        content_type: 'application/octet-stream'
      )

      expect(document).not_to be_valid
      expect(document.errors[:source_file]).to include(I18n.t('captain.documents.file_upload_format_error'))
    end

    it 'returns a blob display URL for uploaded office files' do
      uploaded_file_document.save!

      expect(uploaded_file_document.display_url).to be_present
    end
  end

  describe 'response builder job callback' do
    before { clear_enqueued_jobs }

    describe 'non-PDF documents' do
      it 'enqueues when created with available status and content' do
        expect do
          create(:captain_document, assistant: assistant, account: account, status: :available)
        end.to have_enqueued_job(Captain::Documents::ResponseBuilderJob)
      end

      it 'does not enqueue when created available without content or source text' do
        expect do
          create(:captain_document, assistant: assistant, account: account, status: :available, content: nil, source_text: nil)
        end.not_to have_enqueued_job(Captain::Documents::ResponseBuilderJob)
      end

      it 'enqueues when created available with source text only' do
        expect do
          create(:captain_document, assistant: assistant, account: account, status: :available, content: nil, source_text: 'Full extracted text')
        end.to have_enqueued_job(Captain::Documents::ResponseBuilderJob)
      end

      it 'does not enqueue or delete FAQ when FAQ generation is disabled' do
        document = create(
          :captain_document,
          assistant: assistant,
          account: account,
          status: :available,
          content: 'Initial content',
          faq_generation_enabled: false
        )
        clear_enqueued_jobs

        expect do
          document.update!(source_text: 'Fresh full text')
        end.not_to have_enqueued_job(Captain::Documents::ResponseBuilderJob)
      end

      it 'enqueues when status transitions to available with existing content' do
        document = create(:captain_document, assistant: assistant, account: account, status: :in_progress)

        expect do
          document.update!(status: :available)
        end.to have_enqueued_job(Captain::Documents::ResponseBuilderJob)
      end

      it 'does not enqueue when status transitions to available without content' do
        document = create(
          :captain_document,
          assistant: assistant,
          account: account,
          status: :in_progress,
          content: nil
        )

        expect do
          document.update!(status: :available)
        end.not_to have_enqueued_job(Captain::Documents::ResponseBuilderJob)
      end

      it 'enqueues when content is populated on an available document' do
        document = create(
          :captain_document,
          assistant: assistant,
          account: account,
          status: :available,
          content: nil
        )
        clear_enqueued_jobs

        expect do
          document.update!(content: 'Fresh content from crawl')
        end.to have_enqueued_job(Captain::Documents::ResponseBuilderJob)
      end

      it 'enqueues when content changes on an available document' do
        document = create(
          :captain_document,
          assistant: assistant,
          account: account,
          status: :available,
          content: 'Initial content'
        )
        clear_enqueued_jobs

        expect do
          document.update!(content: 'Updated crawl content')
        end.to have_enqueued_job(Captain::Documents::ResponseBuilderJob)
      end

      it 'does not enqueue when content is cleared on an available document' do
        document = create(
          :captain_document,
          assistant: assistant,
          account: account,
          status: :available,
          content: 'Initial content'
        )
        clear_enqueued_jobs

        expect do
          document.update!(content: nil)
        end.not_to have_enqueued_job(Captain::Documents::ResponseBuilderJob)
      end

      it 'does not enqueue for metadata-only updates' do
        document = create(:captain_document, assistant: assistant, account: account, status: :available)
        clear_enqueued_jobs

        expect do
          document.update!(metadata: { 'title' => 'Updated Again' })
        end.not_to have_enqueued_job(Captain::Documents::ResponseBuilderJob)
      end

      it 'does not enqueue while document remains in progress' do
        document = create(:captain_document, assistant: assistant, account: account, status: :in_progress)

        expect do
          document.update!(metadata: { 'title' => 'Updated' })
        end.not_to have_enqueued_job(Captain::Documents::ResponseBuilderJob)
      end
    end

    describe 'PDF documents' do
      def build_pdf_document(status:, content:)
        build(
          :captain_document,
          assistant: assistant,
          account: account,
          status: status,
          content: content
        ).tap do |doc|
          doc.pdf_file.attach(
            io: StringIO.new('PDF content'),
            filename: 'sample.pdf',
            content_type: 'application/pdf'
          )
        end
      end

      it 'enqueues when created available without content' do
        document = build_pdf_document(status: :available, content: nil)

        expect do
          document.save!
        end.to have_enqueued_job(Captain::Documents::ResponseBuilderJob)
      end

      it 'enqueues when status transitions to available' do
        document = build_pdf_document(status: :in_progress, content: nil)
        document.save!
        clear_enqueued_jobs

        expect do
          document.update!(status: :available)
        end.to have_enqueued_job(Captain::Documents::ResponseBuilderJob)
      end

      it 'enqueues when extracted source text updates on an available PDF' do
        document = build_pdf_document(status: :available, content: nil)
        document.save!
        clear_enqueued_jobs

        expect do
          document.update!(source_text: 'Extracted PDF text')
        end.to have_enqueued_job(Captain::Documents::ResponseBuilderJob)
      end
    end

    it 'does not enqueue when the document is destroyed' do
      document = create(:captain_document, assistant: assistant, account: account, status: :available)
      clear_enqueued_jobs

      expect do
        document.destroy!
      end.not_to have_enqueued_job(Captain::Documents::ResponseBuilderJob)
    end
  end

  describe 'firecrawl source documents' do
    it 'filters derived documents out of source_documents scope' do
      source_document = create(:captain_document, assistant: assistant, account: account)
      derived_document = create(
        :captain_document,
        assistant: assistant,
        account: account,
        metadata: {
          'firecrawl' => { 'root_document_id' => source_document.id }
        }
      )

      expect(described_class.source_documents).to include(source_document)
      expect(described_class.source_documents).not_to include(derived_document)
    end

    it 'destroys derived documents when source document is removed' do
      source_document = create(:captain_document, assistant: assistant, account: account)
      derived_document = create(
        :captain_document,
        assistant: assistant,
        account: account,
        metadata: {
          'firecrawl' => { 'root_document_id' => source_document.id }
        }
      )

      expect do
        source_document.destroy!
      end.to change(described_class, :count).by(-2)

      expect { derived_document.reload }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end
end
