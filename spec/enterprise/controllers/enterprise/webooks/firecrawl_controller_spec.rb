require 'rails_helper'

RSpec.describe 'Firecrawl Webhooks', type: :request do
  describe 'POST /enterprise/webhooks/firecrawl?assistant_id=:assistant_id&token=***' do
    let!(:api_key) { create(:installation_config, name: 'CAPTAIN_FIRECRAWL_API_KEY', value: 'test_api_key_123') }
    let!(:account) { create(:account) }
    let!(:assistant) { create(:captain_assistant, account: account) }

    let(:payload_data) do
      {
        markdown: 'hello world',
        metadata: { ogUrl: 'https://example.com' }
      }
    end
    let(:parsed_payload_data) { payload_data.deep_stringify_keys }

    let(:token_helper) { Class.new { include Captain::FirecrawlHelper }.new }
    let(:valid_token) do
      token_helper.generate_firecrawl_token(assistant.id, assistant.account_id)
    end

    let(:import_run_id) { SecureRandom.uuid }
    let(:source_document) do
      create(
        :captain_document,
        account: account,
        assistant: assistant,
        metadata: {
          'firecrawl' => {
            'job_id' => 'job-123',
            'sync' => { 'import_run_id' => import_run_id, 'status' => 'processing' }
          }
        }
      )
    end
    let(:source_token) do
      token_helper.generate_firecrawl_token(
        assistant.id,
        assistant.account_id,
        document_id: source_document.id,
        import_run_id: import_run_id
      )
    end
    let(:source_webhook_path) do
      query = URI.encode_www_form(
        assistant_id: assistant.id,
        document_id: source_document.id,
        import_run_id: import_run_id,
        token: source_token
      )
      "/enterprise/webhooks/firecrawl?#{query}"
    end

    context 'with valid token' do
      context 'with crawl.page event type' do
        let(:valid_params) do
          {
            type: 'crawl.page',
            data: [payload_data]
          }
        end

        it 'processes the webhook and returns success' do
          expect(Captain::Tools::FirecrawlParserJob).to receive(:perform_later)
            .with(
              assistant_id: assistant.id,
              payload: parsed_payload_data,
              source_document_id: nil,
              import_run_id: nil
            )

          post(
            "/enterprise/webhooks/firecrawl?assistant_id=#{assistant.id}&token=#{valid_token}",
            params: valid_params,
            as: :json
          )
          expect(response).to have_http_status(:ok)
          expect(response.body).to be_empty
        end

        it 'passes a workspace-owned source document to the parser' do
          import_run_id = SecureRandom.uuid
          source_document = create(
            :captain_document,
            account: account,
            assistant: nil,
            visibility: :general,
            metadata: { 'firecrawl' => { 'sync' => { 'import_run_id' => import_run_id } } }
          )
          source_token = token_helper.generate_firecrawl_token(
            assistant.id,
            assistant.account_id,
            document_id: source_document.id,
            import_run_id: import_run_id
          )

          expect(Captain::Tools::FirecrawlParserJob).to receive(:perform_later)
            .with(
              assistant_id: assistant.id,
              payload: parsed_payload_data,
              source_document_id: source_document.id,
              import_run_id: import_run_id,
              job_id: 'early-job'
            )

          query = URI.encode_www_form(
            assistant_id: assistant.id,
            document_id: source_document.id,
            import_run_id: import_run_id,
            token: source_token
          )
          post(
            "/enterprise/webhooks/firecrawl?#{query}",
            params: valid_params.merge(id: 'early-job'),
            as: :json
          )
          expect(response).to have_http_status(:conflict)
          expect(source_document.reload.import_job_id).to be_nil

          source_document.mark_import_started!(job_id: 'early-job', import_run_id: import_run_id)
          post(
            "/enterprise/webhooks/firecrawl?#{query}",
            params: valid_params.merge(id: 'early-job'),
            as: :json
          )
          expect(response).to have_http_status(:ok)
          expect(source_document.reload.import_job_id).to eq('early-job')
        end

        it 'does not process another assistant personal source document' do
          other_assistant = create(:captain_assistant, account: account)
          import_run_id = SecureRandom.uuid
          other_source_document = create(
            :captain_document,
            account: account,
            assistant: other_assistant,
            visibility: :personal,
            metadata: { 'firecrawl' => { 'sync' => { 'import_run_id' => import_run_id } } }
          )
          source_token = token_helper.generate_firecrawl_token(
            assistant.id,
            assistant.account_id,
            document_id: other_source_document.id,
            import_run_id: import_run_id
          )

          expect(Captain::Tools::FirecrawlParserJob).not_to receive(:perform_later)

          query = URI.encode_www_form(
            assistant_id: assistant.id,
            document_id: other_source_document.id,
            import_run_id: import_run_id,
            token: source_token
          )
          post(
            "/enterprise/webhooks/firecrawl?#{query}",
            params: valid_params,
            as: :json
          )
          expect(response).to have_http_status(:ok)
        end
      end

      context 'with crawl.completed event type' do
        let(:valid_params) do
          {
            type: 'crawl.completed'
          }
        end

        it 'returns success without enqueuing job when no source document is provided' do
          expect(Captain::Tools::FirecrawlParserJob).not_to receive(:perform_later)

          post("/enterprise/webhooks/firecrawl?assistant_id=#{assistant.id}&token=#{valid_token}",
               params: valid_params,
               as: :json)

          expect(response).to have_http_status(:ok)
          expect(response.body).to be_empty
        end

        it 'does not finalize another assistant personal source document' do
          other_assistant = create(:captain_assistant, account: account)
          import_run_id = SecureRandom.uuid
          other_source_document = create(
            :captain_document,
            account: account,
            assistant: other_assistant,
            visibility: :personal,
            metadata: { 'firecrawl' => { 'sync' => { 'status' => 'queued', 'import_run_id' => import_run_id } } }
          )
          source_token = token_helper.generate_firecrawl_token(
            assistant.id,
            assistant.account_id,
            document_id: other_source_document.id,
            import_run_id: import_run_id
          )

          expect(Captain::Documents::FinalizeImportJob).not_to receive(:perform_later)

          query = URI.encode_www_form(
            assistant_id: assistant.id,
            document_id: other_source_document.id,
            import_run_id: import_run_id,
            token: source_token
          )
          post("/enterprise/webhooks/firecrawl?#{query}", params: valid_params, as: :json)

          expect(response).to have_http_status(:ok)
          expect(other_source_document.reload.firecrawl_sync['status']).to eq('queued')
        end
      end
    end

    context 'with bounded and run-scoped payloads' do
      it 'ignores a stale import run' do
        source_webhook_path
        source_document.update!(
          metadata: source_document.metadata.deep_merge(
            'firecrawl' => { 'sync' => { 'import_run_id' => SecureRandom.uuid } }
          )
        )
        expect(Captain::Tools::FirecrawlParserJob).not_to receive(:perform_later)

        post source_webhook_path, params: { type: 'crawl.page', id: 'job-123', data: [payload_data] }, as: :json

        expect(response).to have_http_status(:ok)
      end

      it 'ignores an event from another Firecrawl job' do
        expect(Captain::Tools::FirecrawlParserJob).not_to receive(:perform_later)

        post source_webhook_path, params: { type: 'crawl.page', id: 'other-job', data: [payload_data] }, as: :json

        expect(response).to have_http_status(:ok)
      end

      it 'ignores a terminal event without the bound Firecrawl job id' do
        expect(Captain::Documents::FinalizeImportJob).not_to receive(:set)

        post source_webhook_path, params: { type: 'crawl.completed', data: [] }, as: :json

        expect(response).to have_http_status(:ok)
        expect(source_document.reload.sync_status).to eq('processing')
      end

      it 'handles a non-object JSON payload without raising' do
        expect(Captain::Tools::FirecrawlParserJob).not_to receive(:perform_later)
        expect(Captain::Documents::FinalizeImportJob).not_to receive(:set)

        post source_webhook_path, params: '[]', headers: { 'Content-Type' => 'application/json' }

        expect(response).to have_http_status(:ok)
        expect(source_document.reload.sync_status).to eq('processing')
      end

      it 'rejects a token bound to another document' do
        other_document = create(:captain_document, account: account, assistant: assistant)
        query = URI.encode_www_form(
          assistant_id: assistant.id,
          document_id: other_document.id,
          import_run_id: import_run_id,
          token: source_token
        )

        post "/enterprise/webhooks/firecrawl?#{query}", params: { type: 'crawl.page', data: [payload_data] }, as: :json

        expect(response).to have_http_status(:unauthorized)
      end

      it 'rejects an expired signed token' do
        path = source_webhook_path

        travel_to 8.days.from_now do
          post path, params: { type: 'crawl.page', data: [payload_data] }, as: :json
        end

        expect(response).to have_http_status(:unauthorized)
      end

      it 'rejects an invalid HMAC when a signature header is provided' do
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with('FIRECRAWL_WEBHOOK_SECRET').and_return('webhook-secret')

        post source_webhook_path,
             params: { type: 'crawl.page', data: [payload_data] },
             headers: { 'X-Firecrawl-Signature' => 'sha256=invalid' },
             as: :json

        expect(response).to have_http_status(:unauthorized)
      end

      it 'fails a source import when a page event has no URL' do
        expect(Captain::Tools::FirecrawlParserJob).not_to receive(:perform_later)

        post source_webhook_path,
             params: { id: 'job-123', type: 'crawl.page', data: [{ markdown: 'missing URL' }] },
             as: :json

        expect(response).to have_http_status(:ok)
        expect(source_document.reload).to be_failed
        expect(source_document.firecrawl_sync['last_error']).to eq('Firecrawl page event is missing URL')
      end

      it 'rejects a token bound to another assistant in the same account' do
        other_assistant = create(:captain_assistant, account: account)
        query = URI.encode_www_form(
          assistant_id: other_assistant.id,
          document_id: source_document.id,
          import_run_id: import_run_id,
          token: source_token
        )

        post "/enterprise/webhooks/firecrawl?#{query}", params: { type: 'crawl.page', data: [payload_data] }, as: :json

        expect(response).to have_http_status(:unauthorized)
      end

      it 'rejects a token bound to another account' do
        other_assistant = create(:captain_assistant, account: create(:account))
        query = URI.encode_www_form(
          assistant_id: other_assistant.id,
          document_id: source_document.id,
          import_run_id: import_run_id,
          token: source_token
        )

        post "/enterprise/webhooks/firecrawl?#{query}", params: { type: 'crawl.page', data: [payload_data] }, as: :json

        expect(response).to have_http_status(:unauthorized)
      end

      it 'rejects more page events than the configured limit' do
        stub_const('Enterprise::Webhooks::FirecrawlController::MAX_PAGE_EVENTS', 1)

        post source_webhook_path, params: { id: 'job-123', type: 'crawl.page', data: [payload_data, payload_data] }, as: :json

        expect(response).to have_http_status(:content_too_large)
      end

      it 'rejects a request body above the configured byte limit' do
        stub_const('Enterprise::Webhooks::FirecrawlController::MAX_REQUEST_BYTES', 128)

        post source_webhook_path,
             params: { type: 'crawl.page', data: [{ markdown: 'x' * 256 }] }.to_json,
             headers: { 'Content-Type' => 'application/json' }

        expect(response).to have_http_status(:content_too_large)
      end

      it 'records oversized markdown as a failed page without enqueueing it' do
        stub_const('Captain::Tools::FirecrawlParserJob::MAX_MARKDOWN_BYTES', 10)
        expect(Captain::Tools::FirecrawlParserJob).not_to receive(:perform_later)

        post source_webhook_path,
             params: {
               id: 'job-123',
               type: 'crawl.page',
               data: [{ markdown: 'x' * 11, metadata: { url: 'https://example.com/oversized' } }]
             },
             as: :json

        expect(response).to have_http_status(:ok)
        expect(source_document.reload.failed_urls).to eq(['https://example.com/oversized'])
      end
    end

    it 'ignores a retry_failed page outside the expected retry set' do
      source_document.update!(
        metadata: source_document.metadata.deep_merge(
          'firecrawl' => {
            'sync' => {
              'refresh_mode' => 'retry_failed',
              'retry_urls' => ['https://example.com/expected'],
              'failed_urls' => []
            }
          }
        )
      )
      expect(Captain::Tools::FirecrawlParserJob).not_to receive(:perform_later)

      post source_webhook_path,
           params: {
             id: 'job-123',
             type: 'crawl.page',
             data: [{ markdown: 'unexpected', metadata: { url: 'https://example.com/unexpected' } }]
           },
           as: :json

      expect(response).to have_http_status(:ok)
      expect(source_document.reload.received_urls).to be_empty
    end

    context 'with invalid token' do
      let(:invalid_params) do
        {
          type: 'crawl.page',
          data: [payload_data]
        }
      end

      it 'returns unauthorized status' do
        post("/enterprise/webhooks/firecrawl?assistant_id=#{assistant.id}&token=invalid_token",
             params: invalid_params,
             as: :json)

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'with invalid assistant_id' do
      context 'with non-existent assistant_id' do
        it 'returns unauthorized status' do
          post("/enterprise/webhooks/firecrawl?assistant_id=invalid_id&token=#{valid_token}",
               params: { type: 'crawl.page', data: [payload_data] },
               as: :json)

          expect(response).to have_http_status(:unauthorized)
        end
      end

      context 'with nil assistant_id' do
        it 'returns unauthorized status' do
          post("/enterprise/webhooks/firecrawl?token=#{valid_token}",
               params: { type: 'crawl.page', data: [payload_data] },
               as: :json)

          expect(response).to have_http_status(:unauthorized)
        end
      end
    end

    context 'when CAPTAIN_FIRECRAWL_API_KEY is not configured' do
      before do
        api_key.destroy
      end

      it 'still accepts a valid signed callback token' do
        expect(Captain::Tools::FirecrawlParserJob).to receive(:perform_later)
          .with(
            assistant_id: assistant.id,
            payload: parsed_payload_data,
            source_document_id: nil,
            import_run_id: nil
          )

        post("/enterprise/webhooks/firecrawl?assistant_id=#{assistant.id}&token=#{valid_token}",
             params: { type: 'crawl.page', data: [payload_data] },
             as: :json)

        expect(response).to have_http_status(:ok)
      end
    end
  end
end
