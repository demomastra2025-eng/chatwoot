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

  it 'creates a standalone deal without contacts or company' do
    post path,
         params: {
           title: 'Inbound without links'
         },
         headers: headers,
         as: :json

    deal = account.crm_deals.find(response.parsed_body.dig('payload', 'id'))

    expect(response).to have_http_status(:created)
    expect(response.parsed_body.dig('payload', 'pipeline_id')).to be_present
    expect(response.parsed_body.dig('payload', 'stage_id')).to be_present
    expect(response.parsed_body.dig('payload', 'company_id')).to be_nil
    expect(response.parsed_body.dig('payload', 'primary_contact_id')).to be_nil
    expect(deal.company_id).to be_nil
    expect(deal.originating_conversation_id).to be_nil
    expect(deal.deal_contacts).to be_empty
  end

  it 'updates a deal to remove contacts and company' do
    company = create(:company, account: account)
    contact = create(:contact, :with_email, account: account, company: company)
    deal = create(:crm_deal, account: account, company: company)
    create(:crm_deal_contact, account: account, deal: deal, contact: contact, primary: true)

    patch "#{path}/#{deal.id}",
          params: {
            title: deal.title,
            company_id: nil,
            contact_ids: [],
            primary_contact_id: nil,
            lock_version: deal.lock_version
          },
          headers: headers,
          as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('payload', 'company_id')).to be_nil
    expect(response.parsed_body.dig('payload', 'primary_contact_id')).to be_nil
    expect(deal.reload.company_id).to be_nil
    expect(deal.originating_conversation_id).to be_nil
    expect(deal.deal_contacts).to be_empty
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
    Crm::Bootstrap::AccountService.new(account: account).perform
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

  it 'reorders deals inside a stage using board position' do
    Crm::Bootstrap::AccountService.new(account: account).perform
    pipeline = account.crm_pipelines.find_by!(code: 'sales_pipeline')
    stage = pipeline.stages.find_by!(code: 'new')
    first_deal = create(:crm_deal, account: account, pipeline: pipeline, stage: stage)
    second_deal = create(:crm_deal, account: account, pipeline: pipeline, stage: stage)
    third_deal = create(:crm_deal, account: account, pipeline: pipeline, stage: stage)

    patch "#{path}/#{third_deal.id}",
          params: {
            lock_version: third_deal.lock_version,
            position: 1
          },
          headers: headers,
          as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('payload', 'position')).to eq(1)
    expect(stage.deals.kept.order(:position, :id).pluck(:id)).to eq(
      [third_deal.id, first_deal.id, second_deal.id]
    )
  end

  it 'blocks moving a deal to a closed stage when required custom fields are missing' do
    Crm::Bootstrap::AccountService.new(account: account).perform
    pipeline = account.crm_pipelines.find_by!(code: 'sales_pipeline')
    open_stage = pipeline.stages.find_by!(code: 'new')
    won_stage = pipeline.stages.find_by!(code: 'won')
    create(
      :crm_field_definition,
      account: account,
      entity_kind: 'deal',
      key: 'decision_maker',
      label: 'Decision maker',
      required: true
    )
    deal = create(:crm_deal, account: account, pipeline: pipeline, stage: open_stage)

    post "#{path}/#{deal.id}/transition_stage",
         params: { stage_id: won_stage.id, lock_version: deal.lock_version },
         headers: headers,
         as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body['code']).to eq('DEAL_STAGE_REQUIRES_FIELDS')
    expect(response.parsed_body['error']).to include('Decision maker')
    expect(response.parsed_body.dig('details', 'missing_fields')).to include(
      { 'key' => 'decision_maker', 'label' => 'Decision maker' }
    )
    expect(deal.reload.stage_id).to eq(open_stage.id)
    expect(deal.closed_at).to be_nil
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

  it 'returns compact company and primary contact in the deal payload' do
    company = create(:company, account: account, name: 'Onelink LLC')
    contact = create(:contact, :with_email, account: account, company: company, name: 'Aruzhan')
    deal = create(:crm_deal, account: account, company: company)
    create(:crm_deal_contact, account: account, deal: deal, contact: contact, primary: true)

    get path, headers: headers, as: :json

    payload = response.parsed_body.fetch('payload').first

    expect(response).to have_http_status(:ok)
    expect(payload.dig('company', 'name')).to eq('Onelink LLC')
    expect(payload.dig('primary_contact', 'name')).to eq('Aruzhan')
  end

  it 'filters deals by managed custom field values' do
    create(
      :crm_field_definition,
      account: account,
      entity_kind: 'deal',
      key: 'deal_size_band',
      label: 'Deal size',
      field_type: 'select',
      options: [{ 'label' => 'Enterprise', 'value' => 'enterprise' }]
    )
    create(
      :crm_field_definition,
      account: account,
      entity_kind: 'deal',
      key: 'budget_score',
      label: 'Budget score',
      field_type: 'number'
    )

    matching_deal = create(
      :crm_deal,
      account: account,
      custom_attributes: {
        'budget_score' => 88,
        'deal_size_band' => 'enterprise'
      }
    )
    create(
      :crm_deal,
      account: account,
      custom_attributes: {
        'budget_score' => 32,
        'deal_size_band' => 'mid_market'
      }
    )

    get path,
        params: {
          custom_attribute_filters: {
            budget_score: { operator: 'greater_than', value: 50 },
            deal_size_band: ['enterprise']
          }
        },
        headers: headers,
        as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body['payload'].map { |deal| deal['id'] }).to eq([matching_deal.id])
  end

  it 'drops custom field values when their field definition becomes inactive' do
    field_definition = create(
      :crm_field_definition,
      account: account,
      entity_kind: 'deal',
      key: 'lead_source_code',
      label: 'Lead source'
    )
    deal = create(
      :crm_deal,
      account: account,
      custom_attributes: { 'lead_source_code' => 'referral' }
    )

    patch "/api/v1/accounts/#{account.id}/crm/field_definitions/#{field_definition.id}",
          params: { active: false },
          headers: headers,
          as: :json

    expect(response).to have_http_status(:ok)

    patch "#{path}/#{deal.id}",
          params: {
            title: 'Updated deal title',
            lock_version: deal.lock_version
          },
          headers: headers,
          as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('payload', 'custom_attributes')).to eq({})
    expect(deal.reload.custom_attributes).to eq({})
  end

  it 'filters deals by originating conversation' do
    conversation = create(:conversation, account: account)
    matching_deal = create(
      :crm_deal,
      account: account,
      originating_conversation: conversation
    )
    create(:crm_deal, account: account)

    get path,
        params: { originating_conversation_id: conversation.id },
        headers: headers,
        as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('meta', 'count')).to eq(1)
    expect(response.parsed_body.dig('payload', 0, 'id')).to eq(matching_deal.id)
  end
end
