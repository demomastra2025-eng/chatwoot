require 'rails_helper'

RSpec.describe 'Captain knowledge selections', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:headers) { admin.create_new_auth_token }
  let(:first_agent) { create(:captain_assistant, account: account) }
  let(:second_agent) { create(:captain_assistant, account: account) }
  let(:third_agent) { create(:captain_assistant, account: account) }

  def payload
    response.parsed_body
  end

  it 'creates one document for multiple selected agents and restricts document/source reads' do
    post "/api/v1/accounts/#{account.id}/captain/documents",
         params: { document: { name: 'Private source', external_link: 'https://example.com/shared-source', visibility: 'personal',
                               assistant_id: nil, allowed_assistant_ids: [first_agent.id, second_agent.id] } },
         headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    expect(payload['allowed_assistant_ids']).to contain_exactly(first_agent.id, second_agent.id)
    expect(payload['restricted_to_assistants']).to be true
    document_id = payload['id']
    expect(account.captain_documents.count).to eq(1)

    get "/api/v1/accounts/#{account.id}/captain/documents/#{document_id}",
        params: { assistant_id: second_agent.id }, headers: headers, as: :json
    expect(response).to have_http_status(:ok)
    get "/api/v1/accounts/#{account.id}/captain/documents/#{document_id}/source_text",
        params: { assistant_id: third_agent.id }, headers: headers, as: :json
    expect(response).to have_http_status(:not_found)
  end

  it 'updates document grants without copying the material' do
    document = create(:captain_document, account: account, assistant: nil, visibility: :personal,
                                        allowed_assistant_ids: [first_agent.id, second_agent.id])

    patch "/api/v1/accounts/#{account.id}/captain/documents/#{document.id}",
          params: { document: { visibility: 'personal', assistant_id: nil, allowed_assistant_ids: [first_agent.id] } },
          headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    expect(payload['allowed_assistant_ids']).to eq([first_agent.id])
    expect(Captain::Document.visible_to_assistant(second_agent.id)).not_to include(document)
  end

  it 'creates and updates selected FAQ grants with the same API contract' do
    post "/api/v1/accounts/#{account.id}/captain/assistant_responses",
         params: { assistant_response: { question: 'Shared question', answer: 'Private answer', visibility: 'personal',
                                         assistant_id: nil, allowed_assistant_ids: [first_agent.id, second_agent.id] } },
         headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    expect(payload['allowed_assistant_ids']).to contain_exactly(first_agent.id, second_agent.id)
    faq_id = payload['id']
    patch "/api/v1/accounts/#{account.id}/captain/assistant_responses/#{faq_id}",
          params: { assistant_response: { visibility: 'personal', assistant_id: nil, allowed_assistant_ids: [first_agent.id] } },
          headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    expect(payload['allowed_assistant_ids']).to eq([first_agent.id])
    get "/api/v1/accounts/#{account.id}/captain/assistant_responses/#{faq_id}",
        params: { assistant_id: second_agent.id }, headers: headers, as: :json
    expect(response).to have_http_status(:not_found)
  end

  it 'rejects empty selections and agents from another workspace' do
    foreign_agent = create(:captain_assistant)
    [[], [foreign_agent.id]].each do |selection|
      expect do
        post "/api/v1/accounts/#{account.id}/captain/assistant_responses",
             params: { assistant_response: { question: 'Shared question', answer: 'Private answer', visibility: 'personal',
                                             assistant_id: nil, allowed_assistant_ids: selection } },
             headers: headers, as: :json
      end.not_to change(Captain::AssistantResponse, :count)
      expect(response).to have_http_status(:unprocessable_entity)
    end
  end
end
