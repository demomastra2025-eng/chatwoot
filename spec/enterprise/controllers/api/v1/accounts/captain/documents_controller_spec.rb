require 'rails_helper'

RSpec.describe 'Api::V1::Accounts::Captain::Documents', type: :request do
  let(:account) { create(:account, custom_attributes: { plan_name: 'startups' }) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:assistant2) { create(:captain_assistant, account: account) }
  let(:document) { create(:captain_document, assistant: nil, account: account) }
  let(:captain_limits) do
    {
      :startups => { :documents => 1, :responses => 100 }
    }.with_indifferent_access
  end

  def json_response
    JSON.parse(response.body, symbolize_names: true)
  end

  describe 'GET /api/v1/accounts/:account_id/captain/documents' do
    context 'when it is an un-authenticated user' do
      before do
        get "/api/v1/accounts/#{account.id}/captain/documents"
      end

      it 'returns unauthorized status' do
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an agent' do
      context 'when no filters are applied' do
        before do
          create_list(:captain_document, 30, assistant: nil, account: account)
        end

        it 'returns the first page of documents' do
          get "/api/v1/accounts/#{account.id}/captain/documents", headers: agent.create_new_auth_token, as: :json

          expect(response).to have_http_status(:ok)
          expect(json_response[:payload].length).to eq(25)
          expect(json_response[:meta]).to eq({ page: 1, total_count: 30 })
        end

        it 'returns the second page of documents' do
          get "/api/v1/accounts/#{account.id}/captain/documents",
              params: { page: 2 },
              headers: agent.create_new_auth_token, as: :json

          expect(response).to have_http_status(:ok)
          expect(json_response[:payload].length).to eq(5)
          expect(json_response[:meta]).to eq({ page: 2, total_count: 30 })
        end
      end

      it 'shows workspace-owned documents without exposing assistant-personal visibility' do
        general_document = create(:captain_document, assistant: nil, account: account, visibility: :general)
        workspace_personal_document = create(:captain_document, assistant: nil, account: account, visibility: :personal)
        personal_document = create(
          :captain_document,
          assistant: assistant,
          account: account,
          visibility: :personal
        )

        get "/api/v1/accounts/#{account.id}/captain/documents", headers: agent.create_new_auth_token, as: :json

        document_ids = json_response[:payload].pluck(:id)
        expect(document_ids).to include(general_document.id, workspace_personal_document.id)
        expect(document_ids).not_to include(personal_document.id)
      end

      context 'when filtering by assistant_id' do
        before do
          create(:captain_document, assistant: nil, account: account, visibility: :general)
          create_list(:captain_document, 3, assistant: assistant, account: account, visibility: :personal)
          create_list(:captain_document, 2, assistant: assistant2, account: account, visibility: :personal)
        end

        it 'returns general workspace documents plus personal documents for the specified assistant' do
          get "/api/v1/accounts/#{account.id}/captain/documents",
              params: { assistant_id: assistant.id },
              headers: agent.create_new_auth_token, as: :json
          expect(response).to have_http_status(:ok)
          expect(json_response[:payload].length).to eq(4)
          assistant_ids = json_response[:payload].pluck(:assistant).compact.pluck(:id).uniq
          expect(assistant_ids).to eq([assistant.id])
        end

        it 'returns general workspace documents when assistant has no personal documents' do
          new_assistant = create(:captain_assistant, account: account)
          get "/api/v1/accounts/#{account.id}/captain/documents",
              params: { assistant_id: new_assistant.id },
              headers: agent.create_new_auth_token, as: :json
          expect(response).to have_http_status(:ok)
          expect(json_response[:payload].length).to eq(1)
          expect(json_response[:payload].first[:assistant]).to be_nil
        end
      end

      context 'when documents belong to different accounts' do
        let(:other_account) { create(:account) }

        before do
          create_list(:captain_document, 3, assistant: nil, account: account)
          create_list(:captain_document, 2, assistant: nil, account: other_account)
        end

        it 'only returns documents for the current account' do
          get "/api/v1/accounts/#{account.id}/captain/documents",
              headers: agent.create_new_auth_token, as: :json
          expect(response).to have_http_status(:ok)
          expect(json_response[:payload].length).to eq(3)
          document_account_ids = json_response[:payload].pluck(:account_id).uniq
          expect(document_account_ids).to eq([account.id])
        end
      end

      context 'with chunk embedding health' do
        it 'returns embedding status summary for each document' do
          document = create(:captain_document, assistant: nil, account: account)
          create(:captain_document_chunk, document: document, account: account, assistant: nil, embedding_status: :indexed)
          create(:captain_document_chunk, document: document, account: account, assistant: nil, embedding_status: :stale)

          get "/api/v1/accounts/#{account.id}/captain/documents",
              headers: agent.create_new_auth_token, as: :json

          expect(response).to have_http_status(:ok)
          expect(json_response[:payload].first[:embedding_status_summary]).to include(
            total: 2,
            indexed: 1,
            pending: 0,
            failed: 0,
            stale: 1,
            degraded: true
          )
        end
      end

      context 'with pagination and assistant filter combined' do
        before do
          create_list(:captain_document, 30, assistant: assistant, account: account, visibility: :personal)
          create_list(:captain_document, 10, assistant: assistant2, account: account, visibility: :personal)
        end

        it 'returns paginated results for specific assistant' do
          get "/api/v1/accounts/#{account.id}/captain/documents",
              params: { assistant_id: assistant.id, page: 2 },
              headers: agent.create_new_auth_token, as: :json
          expect(response).to have_http_status(:ok)
          expect(json_response[:payload].length).to eq(5)
          expect(json_response[:payload][0][:assistant][:id]).to eq(assistant.id)
          expect(json_response[:meta]).to eq({ page: 2, total_count: 30 })
        end
      end
    end
  end

  describe 'GET /api/v1/accounts/:account_id/captain/documents/:id' do
    context 'when it is an un-authenticated user' do
      before do
        get "/api/v1/accounts/#{account.id}/captain/documents/#{document.id}"
      end

      it 'returns unauthorized status' do
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an agent' do
      before do
        get "/api/v1/accounts/#{account.id}/captain/documents/#{document.id}",
            headers: agent.create_new_auth_token, as: :json
      end

      it 'returns success status' do
        expect(response).to have_http_status(:success)
      end

      it 'returns the requested document' do
        expect(json_response[:id]).to eq(document.id)
        expect(json_response[:name]).to eq(document.name)
        expect(json_response[:external_link]).to eq(document.external_link)
      end
    end
  end

  describe 'POST /api/v1/accounts/:account_id/captain/documents' do
    let(:valid_attributes) do
      {
        document: {
          name: 'Test Document',
          external_link: 'https://example.com/doc',
          assistant_id: assistant.id
        }
      }
    end

    let(:invalid_attributes) do
      {
        document: {
          name: 'Test Document'
        }
      }
    end

    context 'when it is an un-authenticated user' do
      before do
        post "/api/v1/accounts/#{account.id}/captain/documents",
             params: valid_attributes, as: :json
      end

      it 'returns unauthorized status' do
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an agent' do
      it 'returns unauthorized' do
        post "/api/v1/accounts/#{account.id}/captain/documents",
             params: valid_attributes,
             headers: agent.create_new_auth_token

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an admin' do
      context 'with valid parameters' do
        it 'creates a new document' do
          expect do
            post "/api/v1/accounts/#{account.id}/captain/documents",
                 params: valid_attributes,
                 headers: admin.create_new_auth_token
          end.to change(Captain::Document, :count).by(1)
        end

        it 'returns success status and the created document' do
          post "/api/v1/accounts/#{account.id}/captain/documents",
               params: valid_attributes,
               headers: admin.create_new_auth_token, as: :json

          expect(response).to have_http_status(:success)
          expect(json_response[:name]).to eq('Test Document')
          expect(json_response[:external_link]).to eq('https://example.com/doc')
          expect(json_response[:faq_generation_enabled]).to be true
        end

        it 'creates a general workspace document without assistant ownership' do
          post "/api/v1/accounts/#{account.id}/captain/documents",
               params: {
                 document: {
                   name: 'Workspace Policy',
                   external_link: 'https://example.com/workspace-policy',
                   visibility: 'general'
                 }
               },
               headers: admin.create_new_auth_token,
               as: :json

          expect(response).to have_http_status(:success)
          expect(json_response[:assistant]).to be_nil
          expect(Captain::Document.last.assistant_id).to be_nil
        end

        it 'creates a workspace-personal document without assistant ownership' do
          expect do
            post "/api/v1/accounts/#{account.id}/captain/documents",
                 params: {
                   document: {
                     name: 'Personal Policy',
                     external_link: 'https://example.com/personal-policy',
                     visibility: 'personal'
                   }
                 },
                 headers: admin.create_new_auth_token,
                 as: :json
          end.to change(Captain::Document, :count).by(1)

          expect(response).to have_http_status(:success)
          expect(json_response[:visibility]).to eq('personal')
          expect(Captain::Document.last.assistant_id).to be_nil
        end

        it 'creates a document with FAQ generation disabled' do
          post "/api/v1/accounts/#{account.id}/captain/documents",
               params: {
                 document: {
                   name: 'Manual only',
                   external_link: 'https://example.com/manual-only',
                   assistant_id: assistant.id,
                   faq_generation_enabled: false
                 }
               },
               headers: admin.create_new_auth_token,
               as: :json

          expect(response).to have_http_status(:success)
          expect(json_response[:faq_generation_enabled]).to be false
          expect(Captain::Document.last.faq_generation_enabled).to be false
        end

        it 'creates a supported remote file url import' do
          allow(Captain::Tools::FirecrawlService).to receive(:configured?).and_return(true)

          post "/api/v1/accounts/#{account.id}/captain/documents",
               params: {
                 document: {
                   name: 'Quarterly Spreadsheet',
                   external_link: 'https://example.com/reports/q1.xlsx',
                   assistant_id: assistant.id,
                   source_mode: 'file_url'
                 }
               },
               headers: admin.create_new_auth_token,
               as: :json

          expect(response).to have_http_status(:success)
          expect(json_response[:source_mode]).to eq('file_url')
          expect(Captain::Document.last.metadata.dig('firecrawl', 'mode')).to eq('file_url')
        end

        it 'creates an uploaded supported office file import' do
          allow(Captain::Tools::FirecrawlService).to receive(:configured?).and_return(true)

          tempfile = Tempfile.new(['report', '.xlsx'])
          tempfile.binmode
          tempfile.write('Spreadsheet content')
          tempfile.rewind

          uploaded_file = Rack::Test::UploadedFile.new(
            tempfile.path,
            'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
            true,
            original_filename: 'report.xlsx'
          )

          post "/api/v1/accounts/#{account.id}/captain/documents",
               params: {
                 document: {
                   name: 'Uploaded Spreadsheet',
                   assistant_id: assistant.id,
                   source_mode: 'file_upload',
                   faq_generation_enabled: false,
                   source_file: uploaded_file
                 }
               },
               headers: admin.create_new_auth_token

          expect(response).to have_http_status(:success)
          expect(json_response[:source_mode]).to eq('file_upload')
          expect(Captain::Document.last.metadata.dig('firecrawl', 'mode')).to eq('file_upload')
          expect(Captain::Document.last.faq_generation_enabled).to be false
          expect(Captain::Document.last.source_file).to be_attached
        ensure
          tempfile.close!
        end
      end

      context 'with invalid parameters' do
        before do
          post "/api/v1/accounts/#{account.id}/captain/documents",
               params: invalid_attributes,
               headers: admin.create_new_auth_token
        end

        it 'returns unprocessable entity status' do
          expect(response).to have_http_status(:unprocessable_content)
        end
      end

      context 'with unsupported file url parameters' do
        before do
          allow(Captain::Tools::FirecrawlService).to receive(:configured?).and_return(true)

          post "/api/v1/accounts/#{account.id}/captain/documents",
               params: {
                 document: {
                   name: 'Unsupported File',
                   external_link: 'https://example.com/page.exe',
                   assistant_id: assistant.id,
                   source_mode: 'file_url'
                 }
               },
               headers: admin.create_new_auth_token,
               as: :json
        end

        it 'returns unprocessable entity status' do
          expect(response).to have_http_status(:unprocessable_content)
        end
      end

      context 'with limits exceeded' do
        before do
          create_list(:captain_document, 5, assistant: assistant, account: account)

          create(:installation_config, name: 'CAPTAIN_CLOUD_PLAN_LIMITS', value: captain_limits.to_json)
          post "/api/v1/accounts/#{account.id}/captain/documents",
               params: valid_attributes,
               headers: admin.create_new_auth_token
        end

        it 'returns an error' do
          expect(response).to have_http_status(:unprocessable_content)
        end
      end
    end
  end

  describe 'DELETE /api/v1/accounts/:account_id/captain/documents/:id' do
    context 'when it is an un-authenticated user' do
      before do
        delete "/api/v1/accounts/#{account.id}/captain/documents/#{document.id}"
      end

      it 'returns unauthorized status' do
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an agent' do
      let!(:document_to_delete) { create(:captain_document, assistant: nil, account: account) }

      it 'deletes the document' do
        delete "/api/v1/accounts/#{account.id}/captain/documents/#{document_to_delete.id}",
               headers: agent.create_new_auth_token

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an admin' do
      context 'when document exists' do
        let!(:document_to_delete) { create(:captain_document, assistant: nil, account: account) }

        it 'deletes the document' do
          expect do
            delete "/api/v1/accounts/#{account.id}/captain/documents/#{document_to_delete.id}",
                   headers: admin.create_new_auth_token
          end.to change(Captain::Document, :count).by(-1)
        end

        it 'returns no content status' do
          delete "/api/v1/accounts/#{account.id}/captain/documents/#{document_to_delete.id}",
                 headers: admin.create_new_auth_token

          expect(response).to have_http_status(:no_content)
        end
      end

      context 'when document does not exist' do
        before do
          delete "/api/v1/accounts/#{account.id}/captain/documents/invalid_id",
                 headers: admin.create_new_auth_token
        end

        it 'returns not found status' do
          expect(response).to have_http_status(:not_found)
        end
      end
    end
  end

  describe 'POST /api/v1/accounts/:account_id/captain/documents/preview' do
    let(:preview_attributes) do
      {
        document: {
          assistant_id: assistant.id,
          external_link: 'https://example.com/docs',
          source_mode: 'selected_pages',
          import_profile: {
            max_pages: 20
          }
        }
      }
    end

    it 'returns preview links for admins' do
      firecrawl_service = instance_double(Captain::Tools::FirecrawlService)
      allow(Captain::Tools::FirecrawlService).to receive(:configured?).and_return(true)
      allow(Captain::Tools::FirecrawlService).to receive(:new).and_return(firecrawl_service)
      allow(firecrawl_service).to receive(:map).and_return(
        double(
          parsed_response: {
            'links' => [
              { 'url' => 'https://example.com/docs/page-1', 'title' => 'Page 1', 'description' => 'Desc' }
            ]
          }
        )
      )

      post "/api/v1/accounts/#{account.id}/captain/documents/preview",
           params: preview_attributes,
           headers: admin.create_new_auth_token,
           as: :json

      expect(response).to have_http_status(:success)
      expect(json_response[:payload].first[:url]).to eq('https://example.com/docs/page-1')
    end
  end

  describe 'POST /api/v1/accounts/:account_id/captain/documents/:id/resync' do
    it 're-queues an existing document import for admins' do
      document
      allow(Captain::Documents::CrawlJob).to receive(:perform_later)

      post "/api/v1/accounts/#{account.id}/captain/documents/#{document.id}/resync",
           headers: admin.create_new_auth_token,
           as: :json

      expect(response).to have_http_status(:success)
      expect(Captain::Documents::CrawlJob).to have_received(:perform_later).with(document)
      expect(document.reload.sync_status).to eq('queued')
    end
  end

  describe 'POST /api/v1/accounts/:account_id/captain/documents/:id/refresh_changed_only' do
    before do
      document.update!(
        metadata: {
          'firecrawl' => {
            'mode' => 'site_import',
            'sync' => { 'status' => 'completed' }
          }
        }
      )
      allow(Captain::Documents::CrawlJob).to receive(:perform_later)
    end

    it 'starts a delta refresh for admins' do
      post "/api/v1/accounts/#{account.id}/captain/documents/#{document.id}/refresh_changed_only",
           headers: admin.create_new_auth_token,
           as: :json

      expect(response).to have_http_status(:success)
      expect(Captain::Documents::CrawlJob).to have_received(:perform_later).with(document)
      expect(document.reload.refresh_mode).to eq('delta')
    end
  end

  describe 'POST /api/v1/accounts/:account_id/captain/documents/:id/retry_failed' do
    before do
      document.update!(
        metadata: {
          'firecrawl' => {
            'mode' => 'site_import',
            'sync' => {
              'status' => 'completed',
              'failed_urls' => ['https://example.com/failed-page']
            }
          }
        }
      )
      allow(Captain::Documents::CrawlJob).to receive(:perform_later)
    end

    it 'retries failed URLs for admins' do
      post "/api/v1/accounts/#{account.id}/captain/documents/#{document.id}/retry_failed",
           headers: admin.create_new_auth_token,
           as: :json

      expect(response).to have_http_status(:success)
      expect(Captain::Documents::CrawlJob).to have_received(:perform_later).with(document)
      expect(document.reload.refresh_mode).to eq('retry_failed')
    end
  end
end
