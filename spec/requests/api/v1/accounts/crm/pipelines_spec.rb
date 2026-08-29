require 'rails_helper'

RSpec.describe 'CRM Pipelines API', type: :request do
  let(:account) { create(:account) }
  let(:administrator) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:headers) { administrator.create_new_auth_token }
  let(:path) { "/api/v1/accounts/#{account.id}/crm/pipelines" }

  before do
    account.enable_features!('crm_deals')
  end

  it 'returns unauthorized without auth' do
    get path, as: :json

    expect(response).to have_http_status(:unauthorized)
  end

  it 'bootstraps default pipelines for administrators' do
    get path, headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('meta', 'count')).to eq(1)
    expect(response.parsed_body.dig('payload', 0, 'code')).to eq('sales_pipeline')
    stages = response.parsed_body.dig('payload', 0, 'stages')
    expect(stages.pluck('code')).to eq(%w[new qualified proposal won lost])
    expect(stages.find { |stage| stage['code'] == 'new' }).to include(
      'system' => true,
      'position' => 0,
      'position_locked' => true
    )
    expect(stages.find { |stage| stage['code'] == 'won' }).to include('outcome' => 'won', 'color' => Crm::Stage::WON_COLOR)
    expect(stages.find { |stage| stage['code'] == 'lost' }).to include('outcome' => 'lost', 'color' => Crm::Stage::LOST_COLOR)
  end

  it 'allows custom-role users with crm_settings_view' do
    custom_role = create(:custom_role, account: account, permissions: ['crm_settings_view'])
    custom_role_user = create(:user, account: account, role: :agent)
    custom_role_user.account_users.find_by(account: account).update!(custom_role: custom_role)

    get path, headers: custom_role_user.create_new_auth_token, as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('meta', 'count')).to eq(1)
  end

  it 'allows plain agents to read deal runtime references' do
    get path, headers: agent.create_new_auth_token, as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('meta', 'count')).to eq(1)
    expect(response.parsed_body.dig('payload', 0, 'code')).to eq('sales_pipeline')
  end

  it 'rejects plain agents from configuring pipelines' do
    post path,
         params: { name: 'Enterprise Sales', code: 'enterprise_sales', default: true },
         headers: agent.create_new_auth_token,
         as: :json

    expect(response).to have_http_status(:unauthorized)
    expect(account.crm_pipelines.where(code: 'enterprise_sales')).not_to exist
  end

  it 'creates a pipeline for administrators' do
    post path,
         params: { name: 'Enterprise Sales', code: 'enterprise_sales', default: true },
         headers: headers,
         as: :json

    expect(response).to have_http_status(:created)
    expect(response.parsed_body.dig('payload', 'code')).to eq('enterprise_sales')
    expect(response.parsed_body.dig('payload', 'default')).to be(true)
    stages = response.parsed_body.dig('payload', 'stages')
    expect(stages.pluck('code')).to eq(%w[new qualified proposal won lost])
    expect(stages.find { |stage| stage['code'] == 'won' }).to include('outcome' => 'won', 'color' => Crm::Stage::WON_COLOR)
    expect(stages.find { |stage| stage['code'] == 'lost' }).to include('outcome' => 'lost', 'color' => Crm::Stage::LOST_COLOR)
    expect(account.crm_pipelines.where(code: 'enterprise_sales')).to exist
  end

  it 'saves primary state and channel-contact auto-create flag' do
    post path,
         params: {
           name: 'Channel Pipeline',
           code: 'channel_pipeline',
           default: true,
           auto_create_deal_on_channel_contact: true
         },
         headers: headers,
         as: :json

    pipeline = account.crm_pipelines.find_by!(code: 'channel_pipeline')

    expect(response).to have_http_status(:created)
    expect(pipeline.default).to be(true)
    expect(pipeline.auto_create_deal_on_channel_contact).to be(true)
    expect(response.parsed_body.dig('payload', 'auto_create_deal_on_channel_contact')).to be(true)
  end

  it 'switches the default pipeline when creating another default pipeline' do
    get path, headers: headers, as: :json
    original_default = account.crm_pipelines.find_by!(code: 'sales_pipeline')

    post path,
         params: { name: 'Enterprise Sales', code: 'enterprise_sales', default: true },
         headers: headers,
         as: :json

    new_default = account.crm_pipelines.find_by!(code: 'enterprise_sales')

    expect(response).to have_http_status(:created)
    expect(new_default.default).to be(true)
    expect(original_default.reload.default).to be(false)
  end

  it 'switches the default pipeline when updating an existing pipeline' do
    get path, headers: headers, as: :json
    original_default = account.crm_pipelines.find_by!(code: 'sales_pipeline')
    pipeline = create(:crm_pipeline, account: account, code: 'enterprise_sales', default: false, active: true)

    patch "#{path}/#{pipeline.id}",
          params: { default: true },
          headers: headers,
          as: :json

    expect(response).to have_http_status(:ok)
    expect(pipeline.reload.default).to be(true)
    expect(original_default.reload.default).to be(false)
  end

  it 'creates a pipeline with a russian name and auto-generated code' do
    post path,
         params: { name: 'Новая воронка продаж', default: false },
         headers: headers,
         as: :json

    expect(response).to have_http_status(:created)
    expect(response.parsed_body.dig('payload', 'code')).to eq('новая_воронка_продаж')
    expect(account.crm_pipelines.where(code: 'новая_воронка_продаж')).to exist
  end

  it 'creates a pipeline at the end when position is omitted' do
    get path, headers: headers, as: :json
    previous_last_position = account.crm_pipelines.maximum(:position)

    post path,
         params: { name: 'Channel Sales', default: false },
         headers: headers,
         as: :json

    created_pipeline = account.crm_pipelines.find_by!(code: 'channel_sales')

    expect(response).to have_http_status(:created)
    expect(created_pipeline.position).to eq(previous_last_position + 1)
    expect(account.crm_pipelines.ordered.last.id).to eq(created_pipeline.id)
  end

  it 'returns deal counts in pipeline and stage payloads' do
    get path, headers: headers, as: :json
    pipeline = account.crm_pipelines.find_by!(code: 'sales_pipeline')
    stage = pipeline.stages.first
    create(:crm_deal, account: account, pipeline: pipeline, stage: stage)
    create(:crm_deal, account: account, pipeline: pipeline, stage: stage, archived_at: 1.day.ago)

    get path, headers: headers, as: :json

    payload = response.parsed_body.fetch('payload')
    sales_pipeline = payload.find { |item| item['id'] == pipeline.id }

    expect(response).to have_http_status(:ok)
    expect(sales_pipeline['deal_count']).to eq(1)
    expect(sales_pipeline.fetch('stages').find { |item| item['id'] == stage.id }['deal_count']).to eq(1)
  end

  it 'returns only active stages in pipeline payloads by default' do
    get path, headers: headers, as: :json
    pipeline = account.crm_pipelines.find_by!(code: 'sales_pipeline')
    active_stage = pipeline.stages.find_by!(code: 'qualified')
    archived_stage = pipeline.stages.find_by!(code: 'proposal')
    archived_stage.update!(active: false)

    get path, headers: headers, as: :json

    sales_pipeline = response.parsed_body.fetch('payload').find { |item| item['id'] == pipeline.id }
    stage_ids = sales_pipeline.fetch('stages').pluck('id')

    expect(response).to have_http_status(:ok)
    expect(stage_ids).to include(active_stage.id)
    expect(stage_ids).not_to include(archived_stage.id)
  end

  it 'can include inactive stages when explicitly requested' do
    get path, headers: headers, as: :json
    pipeline = account.crm_pipelines.find_by!(code: 'sales_pipeline')
    inactive_stage = pipeline.stages.find_by!(code: 'proposal')
    inactive_stage.update!(active: false)

    get path, params: { include_inactive_stages: true }, headers: headers, as: :json

    sales_pipeline = response.parsed_body.fetch('payload').find { |item| item['id'] == pipeline.id }
    stage_ids = sales_pipeline.fetch('stages').pluck('id')

    expect(response).to have_http_status(:ok)
    expect(stage_ids).to include(inactive_stage.id)
  end

  it 'updates default stage list after stage create and archive' do
    get path, headers: headers, as: :json
    pipeline = account.crm_pipelines.find_by!(code: 'sales_pipeline')

    post "/api/v1/accounts/#{account.id}/crm/pipelines/#{pipeline.id}/stages",
         params: { name: 'Follow-up', color: '#14B8A6', outcome: 'open' },
         headers: headers,
         as: :json

    expect(response).to have_http_status(:created)
    created_stage_id = response.parsed_body.dig('payload', 'id')

    get path, headers: headers, as: :json
    sales_pipeline = response.parsed_body.fetch('payload').find { |item| item['id'] == pipeline.id }
    expect(sales_pipeline.fetch('stages').pluck('code')).to eq(
      %w[new qualified proposal follow-up won lost]
    )
    expect(sales_pipeline.fetch('stages').pluck('id')).to include(created_stage_id)

    patch "/api/v1/accounts/#{account.id}/crm/stages/#{created_stage_id}",
          params: { active: false },
          headers: headers,
          as: :json

    expect(response).to have_http_status(:ok)

    get path, headers: headers, as: :json
    sales_pipeline = response.parsed_body.fetch('payload').find { |item| item['id'] == pipeline.id }
    expect(sales_pipeline.fetch('stages').pluck('id')).not_to include(created_stage_id)
  end

  it 'atomically reorders only movable stages inside one pipeline' do
    get path, headers: headers, as: :json
    pipeline = account.crm_pipelines.find_by!(code: 'sales_pipeline')
    follow_up = create(:crm_stage, account: account, pipeline: pipeline, code: 'follow_up')
    movable_stages = pipeline.stages.where(outcome: 'open').where.not(code: 'new')
    ordered_ids = [follow_up.id] + movable_stages.where.not(id: follow_up.id).order(position: :desc).pluck(:id)

    patch "#{path}/#{pipeline.id}/reorder_stages",
          params: { stage_ids: ordered_ids },
          headers: headers,
          as: :json

    ordered_stages = pipeline.reload.stages.ordered

    expect(response).to have_http_status(:ok)
    expect(ordered_stages.first.code).to eq('new')
    expect(ordered_stages.last(2).map(&:outcome)).to eq(%w[won lost])
    expect(ordered_stages.where(outcome: 'open').where.not(code: 'new').pluck(:id)).to eq(ordered_ids)
  end

  it 'rejects incomplete or cross-pipeline stage orders' do
    get path, headers: headers, as: :json
    pipeline = account.crm_pipelines.find_by!(code: 'sales_pipeline')
    other_pipeline = create(:crm_pipeline, account: account)
    foreign_stage = create(:crm_stage, account: account, pipeline: other_pipeline)

    patch "#{path}/#{pipeline.id}/reorder_stages",
          params: { stage_ids: [foreign_stage.id] },
          headers: headers,
          as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body['code']).to eq('INVALID_STAGE_ORDER')

    movable_stage_ids = pipeline.stages.where(outcome: 'open').where.not(code: 'new').pluck(:id)
    duplicate_stage_ids = movable_stage_ids.length > 1 ? [movable_stage_ids.first] * movable_stage_ids.length : []

    patch "#{path}/#{pipeline.id}/reorder_stages",
          params: { stage_ids: duplicate_stage_ids },
          headers: headers,
          as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body['code']).to eq('INVALID_STAGE_ORDER')
  end

  it 'rejects stage reordering without CRM settings management access' do
    get path, headers: headers, as: :json
    pipeline = account.crm_pipelines.find_by!(code: 'sales_pipeline')
    movable_stage_ids = pipeline.stages.where(outcome: 'open').where.not(code: 'new').pluck(:id)

    patch "#{path}/#{pipeline.id}/reorder_stages",
          params: { stage_ids: movable_stage_ids },
          headers: agent.create_new_auth_token,
          as: :json

    expect(response).to have_http_status(:unauthorized)
  end

  it 'deletes an archived pipeline without deals' do
    pipeline = create(:crm_pipeline, account: account, active: false, default: false)
    create(:crm_stage, account: account, pipeline: pipeline)

    delete "#{path}/#{pipeline.id}", headers: headers, as: :json

    expect(response).to have_http_status(:no_content)
    expect(account.crm_pipelines.where(id: pipeline.id)).not_to exist
    expect(account.crm_stages.where(pipeline_id: pipeline.id)).not_to exist
  end

  it 'rejects deleting an active pipeline' do
    pipeline = create(:crm_pipeline, account: account, active: true, default: false)

    delete "#{path}/#{pipeline.id}", headers: headers, as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body['code']).to eq('PIPELINE_MUST_BE_ARCHIVED')
    expect(account.crm_pipelines.where(id: pipeline.id)).to exist
  end

  it 'rejects deleting an archived pipeline with deals' do
    pipeline = create(:crm_pipeline, account: account, active: false, default: false)
    stage = create(:crm_stage, account: account, pipeline: pipeline)
    create(:crm_deal, account: account, pipeline: pipeline, stage: stage)

    delete "#{path}/#{pipeline.id}", headers: headers, as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body['code']).to eq('PIPELINE_HAS_DEALS')
    expect(account.crm_pipelines.where(id: pipeline.id)).to exist
  end

  it 'returns forbidden when crm_deals is disabled' do
    account.disable_features!('crm_deals')

    get path, headers: headers, as: :json

    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body['code']).to eq('FEATURE_DISABLED')
  end
end
