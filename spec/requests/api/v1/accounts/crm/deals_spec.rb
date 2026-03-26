require 'rails_helper'

RSpec.describe 'CRM Deals API', type: :request do
  let(:account) { create(:account) }
  let(:administrator) { create(:user, account: account, role: :administrator) }
  let(:headers) { administrator.create_new_auth_token }
  let(:path) { "/api/v1/accounts/#{account.id}/crm/deals" }

  before do
    account.enable_features!('crm_deals')
  end

  it 'creates a deal with default pipeline and originating conversation contact' do
    contact = create(:contact, :with_email, account: account)
    conversation = create(:conversation, account: account, contact: contact)

    post path,
         params: {
           title: 'Big renewal',
           amount_minor: 250_000,
           currency: 'usd',
           originating_conversation_id: conversation.id
         },
         headers: headers,
         as: :json

    expect(response).to have_http_status(:created)
    expect(response.parsed_body.dig('payload', 'pipeline_id')).to be_present
    expect(response.parsed_body.dig('payload', 'stage_id')).to be_present
    expect(response.parsed_body.dig('payload', 'primary_contact_id')).to eq(contact.id)
    expect(response.parsed_body.dig('payload', 'currency')).to eq('USD')
  end

  it 'returns an existing deal when create is retried with the same idempotency_key' do
    params = {
      title: 'API import',
      company_id: create(:company, account: account).id,
      idempotency_key: 'deal-import-1'
    }

    post path, params: params, headers: headers, as: :json
    first_id = response.parsed_body.dig('payload', 'id')

    post path, params: params, headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('payload', 'id')).to eq(first_id)
  end

  it 'returns conflict for duplicate external_ref' do
    company = create(:company, account: account)
    create(:crm_deal, account: account, company: company, external_ref: 'deal-ext-1')

    post path,
         params: {
           title: 'Retry import',
           company_id: company.id,
           external_ref: 'deal-ext-1'
         },
         headers: headers,
         as: :json

    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body['code']).to eq('DUPLICATE_EXTERNAL_REF')
  end

  it 'transitions a deal to a won stage' do
    bootstrap = Crm::Bootstrap::AccountService.new(account: account).perform
    pipeline = account.crm_pipelines.find_by!(code: 'sales_pipeline')
    open_stage = pipeline.stages.find_by!(code: 'new')
    won_stage = pipeline.stages.find_by!(code: 'won')
    company = create(:company, account: account)
    deal = create(:crm_deal, account: account, pipeline: pipeline, stage: open_stage, company: company)

    post "#{path}/#{deal.id}/transition_stage",
         params: { stage_id: won_stage.id, lock_version: deal.lock_version },
         headers: headers,
         as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('payload', 'stage_id')).to eq(won_stage.id)
    expect(response.parsed_body.dig('payload', 'closed_at')).to be_present
    expect(deal.reload.events.where(event_type: 'deal_stage_changed')).to exist
  end

  it 'allows custom-role users with crm_deal_view to list deals' do
    create(:crm_deal, account: account, company: create(:company, account: account))
    custom_role = create(:custom_role, account: account, permissions: ['crm_deal_view'])
    custom_role_user = create(:user, account: account, role: :agent)
    custom_role_user.account_users.find_by(account: account).update!(custom_role: custom_role)

    get path, headers: custom_role_user.create_new_auth_token, as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('meta', 'count')).to eq(1)
  end
end
