require 'rails_helper'

RSpec.describe 'Contacts Duplicates API', type: :request do
  let(:account) { create(:account) }
  let(:agent) { create(:user, account: account, role: :agent) }

  describe 'GET /api/v1/accounts/{account.id}/contacts/duplicates' do
    it 'returns duplicate pairs for authenticated agent' do
      first = create(
        :contact,
        account: account,
        name: 'Айгуль',
        last_name: 'Смагулова',
        phone_number: '+77015551122',
        custom_attributes: { 'iin' => '900101400123' }
      )
      second = create(
        :contact,
        account: account,
        name: 'Айгуль',
        last_name: 'Смагулова',
        phone_number: nil,
        custom_attributes: { 'iin' => '900101400123' }
      )

      get "/api/v1/accounts/#{account.id}/contacts/duplicates",
          headers: agent.create_new_auth_token,
          as: :json

      expect(response).to have_http_status(:success)
      body = response.parsed_body
      expect(body['meta']['count']).to eq(1)
      expect(body['payload'].first['primary_contact']['id']).to eq(first.id)
      expect(body['payload'].first['conflicting_contact']['id']).to eq(second.id)
    end
  end

  describe 'POST /api/v1/accounts/{account.id}/contacts/dismiss_duplicate' do
    it 'marks pair as separate contacts' do
      first = create(:contact, account: account, name: 'Алия', last_name: 'Оспанова')
      second = create(:contact, account: account, name: 'Алия', last_name: 'Оспанова')

      post "/api/v1/accounts/#{account.id}/contacts/dismiss_duplicate",
           params: { contact_id: first.id, duplicate_contact_id: second.id },
           headers: agent.create_new_auth_token,
           as: :json

      expect(response).to have_http_status(:ok)
      expect(first.reload.custom_attributes['dismissed_duplicate_contact_ids']).to include(second.id)
    end
  end
end
