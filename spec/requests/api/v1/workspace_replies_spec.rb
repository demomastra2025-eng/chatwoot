require 'rails_helper'

RSpec.describe 'Company replies API', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:headers) { admin.create_new_auth_token }
  let!(:inbox) { create(:inbox, account: account) }

  before do
    InboxMember.find_or_create_by!(inbox: inbox, user: admin)
  end

  it 'saves one company setting and returns inherited values for the channel' do
    patch "/api/v1/accounts/#{account.id}", headers: headers,
                                            params: { workspace_greeting: { enabled: true, message: 'Common hello', excluded_inbox_ids: [] },
                                                      workspace_out_of_office: { enabled: true, message: 'Common offline' } }, as: :json
    expect(response).to have_http_status(:ok)
    expect(account.reload.workspace_greeting_message).to eq('Common hello')
    get "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}", headers: headers
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include('greeting_enabled' => true, 'greeting_message' => 'Common hello',
                                            'out_of_office_message' => 'Common offline')
  end

  it 'rejects retired per-channel writes explicitly without partial updates' do
    payload = { name: 'Should not change', greeting_enabled: true, greeting_message: 'Old contract' }
    patch "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}", headers: headers, params: payload, as: :json
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body['error']).to eq('company_managed_settings')
    expect(inbox.reload.name).not_to eq('Should not change')
  end

  it 'does not allow an ordinary employee to change common replies' do
    employee = create(:user, account: account, role: :agent)
    patch "/api/v1/accounts/#{account.id}", headers: employee.create_new_auth_token,
                                            params: { workspace_out_of_office: { enabled: true, message: 'Not allowed' } }, as: :json
    expect(response).to have_http_status(:unauthorized)
    expect(account.reload.workspace_out_of_office_config['enabled']).to be(false)
  end
end
