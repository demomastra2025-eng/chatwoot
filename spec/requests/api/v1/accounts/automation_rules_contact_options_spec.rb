require 'rails_helper'

RSpec.describe 'Automation rules contact condition API', type: :request do
  let(:account) { create(:account) }
  let(:administrator) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:admin_headers) { administrator.create_new_auth_token }
  let(:base_path) { "/api/v1/accounts/#{account.id}/automation_rules" }

  def body
    response.parsed_body
  end

  describe 'GET contact_options' do
    let(:path) { "#{base_path}/contact_options" }

    it 'searches the contacts of the account by name or phone for an administrator' do
      create(:contact, account: account, name: 'Айгерим Нурлан', phone_number: '+77011234567')
      create(:contact, account: account, name: 'Берик', phone_number: '+77025550000')
      create(:contact, account: create(:account), name: 'Айгуль Чужая')

      get path, params: { q: 'айгер' }, headers: admin_headers

      expect(response).to have_http_status(:ok)
      expect(body['payload'].pluck('name')).to eq(['Айгерим Нурлан'])
      expect(body['payload'].first['phone_number']).to eq('+77011234567')
      expect(body['meta']).to include('has_more' => false, 'current_page' => 1)

      get path, params: { q: '702 555' }, headers: admin_headers

      expect(body['payload'].pluck('name')).to eq(['Берик'])
    end

    it 'pages the results' do
      (AutomationRules::ContactOptionsService::PER_PAGE + 1).times { |index| create(:contact, account: account, name: format('Many %03d', index)) }

      get path, params: { q: 'Many' }, headers: admin_headers

      expect(body['payload'].size).to eq(AutomationRules::ContactOptionsService::PER_PAGE)
      expect(body['meta']['has_more']).to be(true)

      get path, params: { q: 'Many', page: 2 }, headers: admin_headers

      expect(body['payload'].size).to eq(1)
      expect(body['meta']['has_more']).to be(false)
    end

    it 'names the contacts behind saved ids, as a list or as a comma separated text' do
      first = create(:contact, account: account, name: 'First')
      second = create(:contact, account: account, name: 'Second')
      foreign = create(:contact, account: create(:account), name: 'Foreign')

      get path, params: { ids: [first.id, second.id, foreign.id, 999_999_999] }, headers: admin_headers

      expect(body['payload'].pluck('name')).to eq(%w[First Second])

      get path, params: { ids: "#{second.id},#{foreign.id}" }, headers: admin_headers

      expect(body['payload'].pluck('name')).to eq(['Second'])
    end

    it 'is for administrators only' do
      get path, params: { q: 'x' }, headers: agent.create_new_auth_token

      expect(response).to have_http_status(:unauthorized)
    end

    it 'requires authentication' do
      get path, params: { q: 'x' }

      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe 'saving a rule with the contact condition' do
    let(:contact) { create(:contact, account: account) }
    let(:params) do
      {
        name: 'Remind everyone but a few',
        description: 'Skips the listed contacts',
        event_name: 'conversation_created',
        conditions: [{ attribute_key: 'contact_id', filter_operator: 'not_equal_to', values: [contact.id], query_operator: nil }],
        actions: [{ action_name: 'send_message', action_params: ['Hello'] }]
      }
    end

    it 'stores the chosen contact ids' do
      post base_path, params: params, headers: admin_headers, as: :json

      expect(response).to have_http_status(:ok)
      rule = account.automation_rules.find(body['id'])
      expected = { 'attribute_key' => 'contact_id', 'filter_operator' => 'not_equal_to', 'values' => [contact.id] }
      expect(rule.conditions).to include(a_hash_including(expected))
    end

    it 'rejects a contact of another account' do
      foreign = create(:contact, account: create(:account))
      params[:conditions] = [{ attribute_key: 'contact_id', filter_operator: 'equal_to', values: [foreign.id], query_operator: nil }]

      post base_path, params: params, headers: admin_headers, as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(body['error']['conditions']).to include('Automation condition values contact_id not supported.')
    end

    it 'keeps toggling a rule after one of its contacts is deleted' do
      post base_path, params: params, headers: admin_headers, as: :json
      rule = account.automation_rules.find(body['id'])
      contact.destroy!

      patch "#{base_path}/#{rule.id}", params: { active: false }, headers: admin_headers, as: :json

      expect(response).to have_http_status(:ok)
      expect(rule.reload.active).to be(false)
    end
  end
end
