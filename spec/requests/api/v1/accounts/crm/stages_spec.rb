require 'rails_helper'

RSpec.describe 'CRM Stages API', type: :request do
  let(:account) { create(:account) }
  let(:administrator) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:headers) { administrator.create_new_auth_token }

  before do
    account.enable_features!('crm_deals')
    Crm::Bootstrap::AccountService.new(account: account).perform
  end

  it 'creates a stage with a selected color' do
    pipeline = account.crm_pipelines.find_by!(code: 'sales_pipeline')

    post "/api/v1/accounts/#{account.id}/crm/pipelines/#{pipeline.id}/stages",
         params: {
           name: 'Negotiation',
           color: '#14B8A6',
           outcome: 'open'
         },
         headers: headers,
         as: :json

    expect(response).to have_http_status(:created)
    expect(response.parsed_body.dig('payload', 'color')).to eq('#14B8A6')
    expect(pipeline.stages.find_by!(code: 'negotiation').color).to eq('#14B8A6')
  end

  it 'rejects plain agents from configuring stages' do
    pipeline = account.crm_pipelines.find_by!(code: 'sales_pipeline')

    post "/api/v1/accounts/#{account.id}/crm/pipelines/#{pipeline.id}/stages",
         params: {
           name: 'Negotiation',
           color: '#14B8A6',
           outcome: 'open'
         },
         headers: agent.create_new_auth_token,
         as: :json

    expect(response).to have_http_status(:unauthorized)
    expect(pipeline.stages.where(code: 'negotiation')).not_to exist
  end

  it 'creates a stage with a russian name and auto-generated code' do
    pipeline = account.crm_pipelines.find_by!(code: 'sales_pipeline')

    post "/api/v1/accounts/#{account.id}/crm/pipelines/#{pipeline.id}/stages",
         params: {
           name: 'Этап продажи',
           color: '#14B8A6',
           outcome: 'open'
         },
         headers: headers,
         as: :json

    expect(response).to have_http_status(:created)
    expect(response.parsed_body.dig('payload', 'code')).to eq('этап_продажи')
    expect(pipeline.stages.find_by!(code: 'этап_продажи').name).to eq('Этап продажи')
  end

  it 'creates a stage at the end of the pipeline when position is omitted' do
    pipeline = account.crm_pipelines.find_by!(code: 'sales_pipeline')
    previous_last_position = pipeline.stages.maximum(:position)

    post "/api/v1/accounts/#{account.id}/crm/pipelines/#{pipeline.id}/stages",
         params: {
           name: 'Final review',
           color: '#14B8A6',
           outcome: 'open'
         },
         headers: headers,
         as: :json

    created_stage = pipeline.stages.find_by!(code: 'final_review')

    expect(response).to have_http_status(:created)
    expect(created_stage.position).to eq(previous_last_position + 1)
    expect(pipeline.reload.stages.ordered.last.id).to eq(created_stage.id)
  end

  it 'updates a stage color' do
    stage = account.crm_stages.find_by!(code: 'proposal')

    patch "/api/v1/accounts/#{account.id}/crm/stages/#{stage.id}",
          params: { color: '#A855F7' },
          headers: headers,
          as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('payload', 'color')).to eq('#A855F7')
    expect(stage.reload.color).to eq('#A855F7')
  end

  it 'rejects duplicate standard colors within the same pipeline' do
    pipeline = account.crm_pipelines.find_by!(code: 'sales_pipeline')
    existing_stage = pipeline.stages.find_by!(code: 'new')

    post "/api/v1/accounts/#{account.id}/crm/pipelines/#{pipeline.id}/stages",
         params: {
           name: 'Duplicate Color Stage',
           color: existing_stage.color,
           outcome: 'open'
         },
         headers: headers,
         as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body['code']).to eq('VALIDATION_ERROR')
    expect(response.parsed_body.dig('details', 'color')).to include(
      'Color has already been taken for this pipeline'
    )
  end

  it 'deletes a stage without deals' do
    pipeline = account.crm_pipelines.find_by!(code: 'sales_pipeline')
    stage = create(
      :crm_stage,
      account: account,
      pipeline: pipeline,
      color: '#123456'
    )

    delete "/api/v1/accounts/#{account.id}/crm/stages/#{stage.id}",
           headers: headers,
           as: :json

    expect(response).to have_http_status(:no_content)
    expect(account.crm_stages.exists?(stage.id)).to be(false)
  end

  it 'rejects deleting a stage with deals' do
    pipeline = account.crm_pipelines.find_by!(code: 'sales_pipeline')
    stage = create(
      :crm_stage,
      account: account,
      pipeline: pipeline,
      color: '#654321'
    )
    create(:crm_deal, account: account, pipeline: pipeline, stage: stage)

    delete "/api/v1/accounts/#{account.id}/crm/stages/#{stage.id}",
           headers: headers,
           as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body['code']).to eq('STAGE_HAS_DEALS')
    expect(account.crm_stages.exists?(stage.id)).to be(true)
  end
end
