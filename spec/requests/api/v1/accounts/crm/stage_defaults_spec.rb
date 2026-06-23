require 'rails_helper'

RSpec.describe 'CRM stage defaults API', type: :request do
  let(:account) { create(:account) }
  let(:administrator) { create(:user, account: account, role: :administrator) }
  let(:headers) { administrator.create_new_auth_token }

  before do
    account.enable_features!('crm_deals')
    Crm::Bootstrap::AccountService.new(account: account).perform
  end

  it 'creates a default stage and clears the previous pipeline default' do
    pipeline = account.crm_pipelines.find_by!(code: 'sales_pipeline')
    previous_default = pipeline.stages.active.find_by(default: true) ||
                       pipeline.stages.active.where(outcome: 'open').ordered.first
    previous_default.update!(default: true)

    post "/api/v1/accounts/#{account.id}/crm/pipelines/#{pipeline.id}/stages",
         params: {
           name: 'Contracting',
           color: '#123456',
           outcome: 'open',
           default: true
         },
         headers: headers,
         as: :json

    created_stage = pipeline.stages.find_by!(code: 'contracting')

    expect(response).to have_http_status(:created)
    expect(response.parsed_body.dig('payload', 'default')).to be(true)
    expect(created_stage).to be_default
    expect(previous_default.reload).not_to be_default
  end

  it 'updates a stage as the pipeline default and clears the previous default' do
    pipeline = account.crm_pipelines.find_by!(code: 'sales_pipeline')
    previous_default = pipeline.stages.active.find_by(default: true) ||
                       pipeline.stages.active.where(outcome: 'open').ordered.first
    previous_default.update!(default: true)
    target_stage = create(
      :crm_stage,
      account: account,
      pipeline: pipeline,
      color: '#123456'
    )

    patch "/api/v1/accounts/#{account.id}/crm/stages/#{target_stage.id}",
          params: { default: true },
          headers: headers,
          as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('payload', 'default')).to be(true)
    expect(target_stage.reload).to be_default
    expect(previous_default.reload).not_to be_default
  end

  it 'creates submitted terminal outcomes as open default stages' do
    pipeline = account.crm_pipelines.find_by!(code: 'sales_pipeline')

    post "/api/v1/accounts/#{account.id}/crm/pipelines/#{pipeline.id}/stages",
         params: {
           name: 'Closed default',
           color: '#123456',
           outcome: 'won',
           active: true,
           default: true
         },
         headers: headers,
         as: :json

    created_stage = pipeline.stages.find_by!(code: 'closed_default')

    expect(response).to have_http_status(:created)
    expect(response.parsed_body.dig('payload', 'outcome')).to eq('open')
    expect(response.parsed_body.dig('payload', 'default')).to be(true)
    expect(created_stage).to be_outcome_open
    expect(created_stage).to be_default
  end
end
