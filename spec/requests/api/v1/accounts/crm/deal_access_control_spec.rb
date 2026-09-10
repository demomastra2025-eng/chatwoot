require 'rails_helper'

RSpec.describe 'CRM Deal AccessRole enforcement', type: :request do
  let(:account) { create(:account) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:other_agent) { create(:user, account: account, role: :agent) }
  let(:headers) { agent.create_new_auth_token }
  let(:path) { "/api/v1/accounts/#{account.id}/crm/deals" }
  let!(:own_deal) { create(:crm_deal, account: account, owner: agent) }
  let!(:other_deal) { create(:crm_deal, account: account, owner: other_agent) }

  before do
    account.enable_features!('crm_deals')
    AccessControl::LegacyRoleAssigner.call(account: account, apply: true)
    AccessControl::ModeTransition.call(account: account, to: :shadow)
    AccessControl::ModeTransition.call(account: account, to: :enforced)
  end

  it 'filters index before pagination and hides an out-of-scope direct URL' do
    get path, headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch('payload').pluck('id')).to contain_exactly(own_deal.id)
    expect(response.parsed_body.dig('meta', 'total_count')).to eq(1)

    get "#{path}/#{other_deal.id}", headers: headers, as: :json

    expect(response).to have_http_status(:not_found)
  end

  it 'rejects mutation of an out-of-scope deal' do
    patch "#{path}/#{other_deal.id}",
          params: { title: 'Forbidden change', lock_version: other_deal.lock_version },
          headers: headers,
          as: :json

    expect(response).to have_http_status(:not_found)
    expect(other_deal.reload.title).not_to eq('Forbidden change')
  end

  it 'does not expose an out-of-scope deal through an idempotent create retry' do
    other_deal.update!(idempotency_key: 'foreign-retry')

    post path,
         params: { title: other_deal.title, idempotency_key: 'foreign-retry' },
         headers: headers,
         as: :json

    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body['code']).to eq('DUPLICATE_IDEMPOTENCY_KEY')
    expect(response.parsed_body).not_to have_key('payload')
  end

  it 'creates an owned deal but rejects assignment outside own scope atomically' do
    post path, params: { title: 'Owned deal' }, headers: headers, as: :json

    expect(response).to have_http_status(:created)
    expect(response.parsed_body.dig('payload', 'owner_id')).to eq(agent.id)

    expect do
      post path,
           params: { title: 'Forbidden assignment', owner_id: other_agent.id },
           headers: headers,
           as: :json
    end.not_to(change { account.crm_deals.where(title: 'Forbidden assignment').count })

    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body['code']).to eq('DEAL_ASSIGNMENT_FORBIDDEN')
  end

  it 'rolls back an out-of-scope reassignment' do
    patch "#{path}/#{own_deal.id}",
          params: { owner_id: other_agent.id, lock_version: own_deal.lock_version },
          headers: headers,
          as: :json

    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body['code']).to eq('DEAL_ASSIGNMENT_FORBIDDEN')
    expect(own_deal.reload.owner).to eq(agent)
  end
end
