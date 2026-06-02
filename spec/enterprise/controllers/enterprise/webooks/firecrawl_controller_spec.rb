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

    # Generate actual token using the helper
    let(:valid_token) do
      token_base = "#{api_key.value[-4..]}#{assistant.id}#{assistant.account_id}"
      Digest::SHA256.hexdigest(token_base)
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
              source_document_id: nil
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
          source_document = create(:captain_document, account: account, assistant: nil, visibility: :general)

          expect(Captain::Tools::FirecrawlParserJob).to receive(:perform_later)
            .with(
              assistant_id: assistant.id,
              payload: parsed_payload_data,
              source_document_id: source_document.id
            )

          post(
            "/enterprise/webhooks/firecrawl?assistant_id=#{assistant.id}&document_id=#{source_document.id}&token=#{valid_token}",
            params: valid_params,
            as: :json
          )
          expect(response).to have_http_status(:ok)
        end

        it 'does not process another assistant personal source document' do
          other_assistant = create(:captain_assistant, account: account)
          other_source_document = create(:captain_document, account: account, assistant: other_assistant, visibility: :personal)

          expect(Captain::Tools::FirecrawlParserJob).not_to receive(:perform_later)

          post(
            "/enterprise/webhooks/firecrawl?assistant_id=#{assistant.id}&document_id=#{other_source_document.id}&token=#{valid_token}",
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
          other_source_document = create(
            :captain_document,
            account: account,
            assistant: other_assistant,
            visibility: :personal,
            metadata: { 'firecrawl' => { 'sync' => { 'status' => 'queued' } } }
          )

          expect(Captain::Documents::FinalizeImportJob).not_to receive(:perform_later)

          post("/enterprise/webhooks/firecrawl?assistant_id=#{assistant.id}&document_id=#{other_source_document.id}&token=#{valid_token}",
               params: valid_params,
               as: :json)

          expect(response).to have_http_status(:ok)
          expect(other_source_document.reload.firecrawl_sync['status']).to eq('queued')
        end
      end
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

      it 'returns unauthorized status' do
        post("/enterprise/webhooks/firecrawl?assistant_id=#{assistant.id}&token=#{valid_token}",
             params: { type: 'crawl.page', data: [payload_data] },
             as: :json)

        expect(response).to have_http_status(:unauthorized)
      end
    end
  end
end
