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

  it 'creates a deal when originating conversation is provided as display id' do
    contact = create(:contact, :with_email, account: account)
    conversation = create(:conversation, account: account, contact: contact, status: :pending)

    post path,
         params: {
           title: 'Deal from conversation panel',
           originating_conversation_id: conversation.display_id
         },
         headers: headers,
         as: :json

    expect(response).to have_http_status(:created)
    expect(response.parsed_body.dig('payload', 'originating_conversation_id')).to eq(conversation.id)
    expect(response.parsed_body.dig('payload', 'originating_conversation_display_id')).to eq(conversation.display_id)
    expect(response.parsed_body.dig('payload', 'originating_communication_thread_id')).to be_nil
    expect(response.parsed_body.dig('payload', 'dialog_kind')).to eq('conversation')
    expect(response.parsed_body.dig('payload', 'dialog_status')).to eq('pending')
    expect(response.parsed_body.dig('payload', 'primary_contact_id')).to eq(contact.id)
  end

  it 'creates a deal from a communication thread display id and binds the thread contact' do
    contact = create(:contact, :with_email, account: account)
    communication_thread = create(:communication_thread, account: account, contact: contact, status: :pending)

    post path,
         params: {
           title: 'Deal from communication thread panel',
           originating_communication_thread_id: communication_thread.display_id
         },
         headers: headers,
         as: :json

    payload = response.parsed_body['payload']
    deal = account.crm_deals.find(payload['id'])

    expect(response).to have_http_status(:created)
    expect(payload).to include(
      'dialog_kind' => 'communication_thread',
      'dialog_status' => 'pending',
      'originating_communication_thread_display_id' => communication_thread.display_id,
      'originating_communication_thread_id' => communication_thread.id,
      'originating_conversation_id' => nil,
      'primary_contact_id' => contact.id
    )
    expect(deal.deal_contacts.find_by(contact_id: contact.id)&.primary).to be(true)
  end

  it 'rejects conflicting conversation and communication thread contacts' do
    conversation = create(:conversation, account: account, contact: create(:contact, account: account))
    communication_thread = create(:communication_thread, account: account, contact: create(:contact, account: account))

    post path,
         params: {
           title: 'Invalid source context',
           originating_conversation_id: conversation.display_id,
           originating_communication_thread_id: communication_thread.display_id
         },
         headers: headers,
         as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body['code']).to eq('VALIDATION_ERROR')
    expect(response.parsed_body.dig('details', 'originating_communication_thread_id')).to be_present
  end

  it 'filters deals to linked pending dialogs when ai_only is enabled' do
    pending_thread = create(:communication_thread, account: account, status: :pending)
    open_thread = create(:communication_thread, account: account, status: :open)
    pending_conversation = create(:conversation, account: account, status: :pending)
    resolved_conversation = create(:conversation, account: account, status: :resolved)
    pending_thread_deal = create(
      :crm_deal,
      account: account,
      originating_communication_thread: pending_thread
    )
    open_thread_deal = create(
      :crm_deal,
      account: account,
      originating_communication_thread: open_thread
    )
    pending_conversation_deal = create(
      :crm_deal,
      account: account,
      originating_conversation: pending_conversation
    )
    resolved_conversation_deal = create(
      :crm_deal,
      account: account,
      originating_conversation: resolved_conversation
    )
    create(:crm_deal, account: account)

    get path, params: { ai_only: true }, headers: headers, as: :json

    payload_ids = response.parsed_body['payload'].pluck('id')

    expect(response).to have_http_status(:ok)
    expect(payload_ids).to contain_exactly(
      pending_thread_deal.id,
      pending_conversation_deal.id
    )
    expect(payload_ids).not_to include(
      open_thread_deal.id,
      resolved_conversation_deal.id
    )
  end

  it 'filters deals by creation date range' do
    matching_deal = create(:crm_deal, account: account, created_at: Time.zone.now)
    create(:crm_deal, account: account, created_at: 10.days.ago)
    create(:crm_deal, account: account, created_at: 2.days.from_now)

    get path,
        params: {
          created_from: 1.day.ago.beginning_of_day.iso8601,
          created_to: 1.day.from_now.end_of_day.iso8601
        },
        headers: headers,
        as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body['payload'].pluck('id')).to eq([matching_deal.id])
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

  it 'auto-selects the first contact as primary when no primary contact is provided' do
    company = create(:company, account: account)
    contact = create(:contact, account: account)

    post path,
         params: {
           title: 'Enterprise upsell',
           company_id: company.id,
           contact_ids: [contact.id]
         },
         headers: headers,
         as: :json

    deal = account.crm_deals.find(response.parsed_body.dig('payload', 'id'))

    expect(response).to have_http_status(:created)
    expect(response.parsed_body.dig('payload', 'primary_contact_id')).to eq(contact.id)
    expect(deal.deal_contacts.find_by(contact_id: contact.id)&.primary).to be(true)
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

  it 'requires a closing reason when the Lost stage toggle is enabled' do
    Crm::Bootstrap::AccountService.new(account: account).perform
    pipeline = account.crm_pipelines.find_by!(code: 'sales_pipeline')
    open_stage = pipeline.stages.find_by!(code: 'new')
    lost_stage = pipeline.stages.find_by!(code: 'lost')
    lost_stage.update!(closing_reason_options: ['Too expensive', 'Competitor'], closing_reason_required: true)
    deal = create(:crm_deal, account: account, pipeline: pipeline, stage: open_stage)

    post "#{path}/#{deal.id}/transition_stage",
         params: { stage_id: lost_stage.id, lock_version: deal.lock_version },
         headers: headers,
         as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body['code']).to eq('VALIDATION_ERROR')
    expect(deal.reload.stage_id).to eq(open_stage.id)
  end

  it 'stores selected closing reasons on the deal and stage-change event' do
    Crm::Bootstrap::AccountService.new(account: account).perform
    pipeline = account.crm_pipelines.find_by!(code: 'sales_pipeline')
    open_stage = pipeline.stages.find_by!(code: 'new')
    lost_stage = pipeline.stages.find_by!(code: 'lost')
    lost_stage.update!(closing_reason_options: ['Too expensive', 'Competitor'], closing_reason_required: true)
    deal = create(:crm_deal, account: account, pipeline: pipeline, stage: open_stage)

    post "#{path}/#{deal.id}/transition_stage",
         params: {
           closing_reasons: ['competitor'],
           stage_id: lost_stage.id,
           lock_version: deal.lock_version
         },
         headers: headers,
         as: :json

    event = deal.reload.events.where(event_type: 'deal_stage_changed').last

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('payload', 'closing_reasons')).to eq(['Competitor'])
    expect(deal.closing_reasons).to eq(['Competitor'])
    expect(event.meta['closing_reasons']).to eq(['Competitor'])
  end

  it 'rejects closing reasons that are not configured for the terminal stage' do
    Crm::Bootstrap::AccountService.new(account: account).perform
    pipeline = account.crm_pipelines.find_by!(code: 'sales_pipeline')
    open_stage = pipeline.stages.find_by!(code: 'new')
    lost_stage = pipeline.stages.find_by!(code: 'lost')
    lost_stage.update!(closing_reason_options: ['Too expensive'], closing_reason_required: false)
    deal = create(:crm_deal, account: account, pipeline: pipeline, stage: open_stage)

    post "#{path}/#{deal.id}/transition_stage",
         params: {
           closing_reasons: ['Other'],
           stage_id: lost_stage.id,
           lock_version: deal.lock_version
         },
         headers: headers,
         as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body['code']).to eq('DEAL_STAGE_INVALID_CLOSING_REASONS')
    expect(response.parsed_body.dig('details', 'invalid_reasons')).to eq(['Other'])
    expect(deal.reload.stage_id).to eq(open_stage.id)
  end

  it 'ignores retired transition reason configuration when moving between open stages' do
    Crm::Bootstrap::AccountService.new(account: account).perform
    pipeline = account.crm_pipelines.find_by!(code: 'sales_pipeline')
    open_stage = pipeline.stages.find_by!(code: 'new')
    proposal_stage = pipeline.stages.find_by!(code: 'proposal')
    proposal_stage.update!(transition_reason_options: ['Needs docs'], transition_reason_required: true)
    deal = create(:crm_deal, account: account, pipeline: pipeline, stage: open_stage)

    post "#{path}/#{deal.id}/transition_stage",
         params: {
           stage_id: proposal_stage.id,
           lock_version: deal.lock_version,
           transition_reason: 'Waiting payment'
         },
         headers: headers,
         as: :json

    event = deal.reload.events.where(event_type: 'deal_stage_changed').last

    expect(response).to have_http_status(:ok)
    expect(deal.stage_id).to eq(proposal_stage.id)
    expect(event.meta).not_to have_key('transition_reason')
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

  it 'blocks entry to an open stage when one of its required fields is missing' do
    pipeline = create(:crm_pipeline, account: account)
    source_stage = create(:crm_stage, account: account, pipeline: pipeline, position: 1)
    target_stage = create(:crm_stage, account: account, pipeline: pipeline, position: 2)
    create(:crm_stage_field_requirement, stage: target_stage, field_key: 'description')
    deal = create(:crm_deal, account: account, pipeline: pipeline, stage: source_stage, description: nil)

    post "#{path}/#{deal.id}/transition_stage",
         params: { stage_id: target_stage.id, lock_version: deal.lock_version },
         headers: headers,
         as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body['code']).to eq('DEAL_STAGE_REQUIRES_FIELDS')
    expect(response.parsed_body.dig('details', 'missing_fields')).to include(
      hash_including('key' => 'description', 'scope' => 'stage')
    )
    expect(deal.reload.stage_id).to eq(source_stage.id)
  end

  it 'allows entry after the stage required field is completed' do
    pipeline = create(:crm_pipeline, account: account)
    source_stage = create(:crm_stage, account: account, pipeline: pipeline, position: 1)
    target_stage = create(:crm_stage, account: account, pipeline: pipeline, position: 2)
    create(:crm_stage_field_requirement, stage: target_stage, field_key: 'description')
    deal = create(:crm_deal, account: account, pipeline: pipeline, stage: source_stage, description: 'Qualified')

    post "#{path}/#{deal.id}/transition_stage",
         params: { stage_id: target_stage.id, lock_version: deal.lock_version },
         headers: headers,
         as: :json

    expect(response).to have_http_status(:ok)
    expect(deal.reload.stage_id).to eq(target_stage.id)
  end

  it 'blocks stage skipping when the pipeline rule is enabled' do
    pipeline = create(:crm_pipeline, account: account, restrict_stage_skipping: true)
    source_stage = create(:crm_stage, account: account, pipeline: pipeline, position: 1)
    create(:crm_stage, account: account, pipeline: pipeline, position: 2)
    target_stage = create(:crm_stage, account: account, pipeline: pipeline, position: 3)
    deal = create(:crm_deal, account: account, pipeline: pipeline, stage: source_stage)

    post "#{path}/#{deal.id}/transition_stage",
         params: { stage_id: target_stage.id, lock_version: deal.lock_version },
         headers: headers,
         as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body['code']).to eq('DEAL_STAGE_ENTRY_RESTRICTED')
    expect(response.parsed_body.dig('details', 'rule_violations')).to include(
      a_hash_including('code' => 'STAGE_SKIPPING_RESTRICTED')
    )
    expect(deal.reload.stage_id).to eq(source_stage.id)
  end

  it 'records an administrator override reason when the pipeline allows it' do
    pipeline = create(
      :crm_pipeline,
      account: account,
      allow_stage_rule_override: true,
      restrict_stage_skipping: true
    )
    source_stage = create(:crm_stage, account: account, pipeline: pipeline, position: 1)
    create(:crm_stage, account: account, pipeline: pipeline, position: 2)
    target_stage = create(:crm_stage, account: account, pipeline: pipeline, position: 3)
    deal = create(:crm_deal, account: account, pipeline: pipeline, stage: source_stage)

    post "#{path}/#{deal.id}/transition_stage",
         params: {
           stage_id: target_stage.id,
           lock_version: deal.lock_version,
           override: true,
           override_reason: 'Customer requested immediate approval'
         },
         headers: headers,
         as: :json

    override = deal.reload.events.where(event_type: 'deal_stage_changed').last.meta.fetch('stage_rule_override')
    expect(response).to have_http_status(:ok)
    expect(deal.stage_id).to eq(target_stage.id)
    expect(override).to include(
      'actor_id' => administrator.id,
      'reason' => 'Customer requested immediate approval',
      'rule_codes' => ['STAGE_SKIPPING_RESTRICTED']
    )
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

  it 'paginates deal lists and returns total metadata' do
    pipeline = create(:crm_pipeline, account: account)
    stage = create(:crm_stage, account: account, pipeline: pipeline)
    create_list(:crm_deal, 3, account: account, pipeline: pipeline, stage: stage)

    get path,
        params: { page: 1, per_page: 2, pipeline_id: pipeline.id },
        headers: headers,
        as: :json

    meta = response.parsed_body['meta']

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body['payload'].size).to eq(2)
    expect(meta).to include(
      'count' => 2,
      'has_more' => true,
      'page' => 1,
      'per_page' => 2,
      'total_count' => 3,
      'total_pages' => 2
    )
    expect(meta.dig('stage_counts', stage.id.to_s)).to eq(3)
  end

  it 'loads one board page for every stage in the pipeline' do
    pipeline = create(:crm_pipeline, account: account)
    first_stage = create(:crm_stage, account: account, pipeline: pipeline)
    second_stage = create(:crm_stage, account: account, pipeline: pipeline)
    create_list(:crm_deal, 3, account: account, pipeline: pipeline, stage: first_stage)
    create_list(:crm_deal, 3, account: account, pipeline: pipeline, stage: second_stage)

    get path,
        params: { board: true, page: 1, per_page: 2, pipeline_id: pipeline.id },
        headers: headers,
        as: :json

    payload = response.parsed_body['payload']
    meta = response.parsed_body['meta']

    expect(response).to have_http_status(:ok)
    expect(payload.group_by { |deal| deal['stage_id'] }.transform_values(&:size)).to eq(
      first_stage.id => 2,
      second_stage.id => 2
    )
    expect(meta).to include(
      'count' => 4,
      'has_more' => true,
      'page' => 1,
      'per_page' => 2,
      'total_count' => 6,
      'total_pages' => 2
    )

    get path,
        params: { board: true, page: 2, per_page: 2, pipeline_id: pipeline.id },
        headers: headers,
        as: :json

    expect(response.parsed_body['payload'].group_by { |deal| deal['stage_id'] }.transform_values(&:size)).to eq(
      first_stage.id => 1,
      second_stage.id => 1
    )
    expect(response.parsed_body.dig('meta', 'has_more')).to be(false)
  end

  it 'paginates each board stage using the selected sort and direction' do
    pipeline = create(:crm_pipeline, account: account)
    stage = create(:crm_stage, account: account, pipeline: pipeline)
    deals = Array.new(10) do |index|
      create(
        :crm_deal,
        account: account,
        amount_minor: (index + 1) * 100,
        currency: 'USD',
        pipeline: pipeline,
        position: index + 1,
        stage: stage
      )
    end

    get path,
        params: {
          board: true,
          board_sort: 'amount',
          board_sort_directions: { stage.id.to_s => 'desc' },
          page: 1,
          per_page: 8,
          pipeline_id: pipeline.id
        },
        headers: headers,
        as: :json

    first_page_ids = response.parsed_body['payload'].pluck('id')

    expect(response).to have_http_status(:ok)
    expect(first_page_ids).to eq(deals.last(8).reverse.map(&:id))

    get path,
        params: {
          board: true,
          board_sort: 'amount',
          board_sort_directions: { stage.id.to_s => 'desc' },
          page: 2,
          per_page: 8,
          pipeline_id: pipeline.id
        },
        headers: headers,
        as: :json

    second_page_ids = response.parsed_body['payload'].pluck('id')

    expect(second_page_ids).to eq(deals.first(2).reverse.map(&:id))
    expect(first_page_ids & second_page_ids).to be_empty
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

  it 'filters deals by originating conversation display id' do
    conversation = create(:conversation, account: account)
    matching_deal = create(
      :crm_deal,
      account: account,
      originating_conversation: conversation
    )
    create(:crm_deal, account: account)

    get path,
        params: { originating_conversation_id: conversation.display_id },
        headers: headers,
        as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('meta', 'count')).to eq(1)
    expect(response.parsed_body.dig('payload', 0, 'id')).to eq(matching_deal.id)
    expect(response.parsed_body.dig('payload', 0, 'originating_conversation_display_id')).to eq(conversation.display_id)
  end

  it 'filters deals by originating communication thread display id' do
    communication_thread = create(:communication_thread, account: account)
    matching_deal = create(
      :crm_deal,
      account: account,
      originating_communication_thread: communication_thread
    )
    create(:crm_deal, account: account)

    get path,
        params: { originating_communication_thread_id: communication_thread.display_id },
        headers: headers,
        as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('meta', 'count')).to eq(1)
    expect(response.parsed_body.dig('payload', 0, 'id')).to eq(matching_deal.id)
    expect(response.parsed_body.dig('payload', 0, 'originating_communication_thread_display_id')).to eq(communication_thread.display_id)
  end

  it 'filters deals by linked contact across conversation sources' do
    contact = create(:contact, account: account)
    conversation = create(:conversation, account: account, contact: contact)
    matching_deal = create(:crm_deal, account: account, originating_conversation: conversation)
    create(:crm_deal_contact, account: account, deal: matching_deal, contact: contact, primary: true)
    create(:crm_deal, account: account)

    get path,
        params: { contact_id: contact.id },
        headers: headers,
        as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('meta', 'count')).to eq(1)
    expect(response.parsed_body.dig('payload', 0, 'id')).to eq(matching_deal.id)
  end

  it 'sets and clears waiting with a structured next action' do
    deal = create(:crm_deal, account: account)
    waiting_until = 2.days.from_now.change(usec: 0)

    post "#{path}/#{deal.id}/set_waiting",
         params: {
           waiting_until: waiting_until.iso8601,
           waiting_reason: 'Waiting for customer approval',
           lock_version: deal.lock_version
         },
         headers: headers,
         as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('payload', 'next_action')).to include(
      'kind' => 'waiting',
      'waiting_reason' => 'Waiting for customer approval'
    )

    deal.reload
    post "#{path}/#{deal.id}/clear_waiting",
         params: { lock_version: deal.lock_version },
         headers: headers,
         as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('payload', 'next_action', 'kind')).to eq('none')
    expect(deal.reload.waiting_until).to be_nil
  end

  it 'creates an optional wake-up task when waiting is set' do
    account.enable_features!('crm_tasks')
    deal = create(:crm_deal, account: account, owner: administrator)
    waiting_until = 1.day.from_now.change(usec: 0)

    post "#{path}/#{deal.id}/set_waiting",
         params: {
           waiting_until: waiting_until.iso8601,
           waiting_reason: 'Call after review',
           create_wake_up_task: true,
           wake_up_task_title: 'Return to customer',
           lock_version: deal.lock_version
         },
         headers: headers,
         as: :json

    wake_up_task = deal.tasks.find_by!(title: 'Return to customer')
    expect(response).to have_http_status(:ok)
    expect(wake_up_task.due_at).to be_within(1.second).of(waiting_until)
    expect(wake_up_task.assignee_id).to eq(administrator.id)
  end

  it 'rejects waiting without a future date and reason' do
    deal = create(:crm_deal, account: account)

    post "#{path}/#{deal.id}/set_waiting",
         params: { waiting_until: 1.hour.ago.iso8601, waiting_reason: '', lock_version: deal.lock_version },
         headers: headers,
         as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body['code']).to eq('VALIDATION_ERROR')
    expect(deal.reload).not_to be_waiting
  end

  it 'filters deals by overdue, missing and expired next actions' do
    account.enable_features!('crm_tasks')
    status = create(:crm_task_status, account: account, category: 'open')
    overdue_deal = create(:crm_deal, account: account)
    no_action_deal = create(:crm_deal, account: account)
    expired_waiting_deal = create(
      :crm_deal,
      account: account,
      waiting_until: 1.hour.ago,
      waiting_reason: 'No reply',
      waiting_started_at: 1.day.ago
    )
    create(:crm_task, account: account, deal: overdue_deal, status: status, due_at: 1.day.ago)

    expected_ids = {
      'overdue' => overdue_deal.id,
      'no_action' => no_action_deal.id,
      'waiting_expired' => expired_waiting_deal.id
    }
    expected_ids.each do |filter, expected_id|
      get path, params: { next_action: filter }, headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['payload'].pluck('id')).to include(expected_id)
    end
  end

  it 'replays a waiting command idempotently without creating a second wake-up task' do
    account.enable_features!('crm_tasks')
    deal = create(:crm_deal, account: account)
    command = {
      waiting_until: 1.day.from_now.change(usec: 0).iso8601,
      waiting_reason: 'Awaiting approval',
      create_wake_up_task: true,
      wake_up_task_title: 'Return to approval',
      lock_version: deal.lock_version,
      idempotency_key: SecureRandom.uuid
    }

    2.times do
      post "#{path}/#{deal.id}/set_waiting", params: command, headers: headers, as: :json
      expect(response).to have_http_status(:ok)
    end

    expect(deal.tasks.where(title: 'Return to approval').count).to eq(1)

    post "#{path}/#{deal.id}/set_waiting",
         params: command.merge(waiting_reason: 'Different reason'),
         headers: headers,
         as: :json

    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body['code']).to eq('IDEMPOTENCY_KEY_REUSED')
  end
end
