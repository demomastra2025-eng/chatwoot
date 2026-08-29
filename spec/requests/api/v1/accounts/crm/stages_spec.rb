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

  it 'creates new stages as open even when a terminal outcome is submitted' do
    pipeline = account.crm_pipelines.find_by!(code: 'sales_pipeline')

    post "/api/v1/accounts/#{account.id}/crm/pipelines/#{pipeline.id}/stages",
         params: {
           name: 'Legal Review',
           color: '#14B8A6',
           outcome: 'won'
         },
         headers: headers,
         as: :json

    created_stage = pipeline.stages.find_by!(code: 'legal_review')

    expect(response).to have_http_status(:created)
    expect(response.parsed_body.dig('payload', 'outcome')).to eq('open')
    expect(created_stage).to be_outcome_open
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

  it 'creates an open stage before terminal won/lost stages when position is omitted' do
    pipeline = account.crm_pipelines.find_by!(code: 'sales_pipeline')
    first_terminal_position = pipeline.stages.where(outcome: Crm::Stage::TERMINAL_OUTCOMES).minimum(:position)

    post "/api/v1/accounts/#{account.id}/crm/pipelines/#{pipeline.id}/stages",
         params: {
           name: 'Final review',
           color: '#14B8A6',
           outcome: 'open'
         },
         headers: headers,
         as: :json

    created_stage = pipeline.stages.find_by!(code: 'final_review')
    ordered_stages = pipeline.reload.stages.ordered.load.to_a
    ordered_outcomes = ordered_stages[-2, 2].map(&:outcome)

    expect(response).to have_http_status(:created)
    expect(created_stage.position).to eq(first_terminal_position)
    expect(ordered_outcomes).to all(be_in(Crm::Stage::TERMINAL_OUTCOMES))
  end

  it 'ignores direct position writes outside the pipeline reorder endpoint' do
    pipeline = account.crm_pipelines.find_by!(code: 'sales_pipeline')
    proposal = pipeline.stages.find_by!(code: 'proposal')
    original_position = proposal.position

    patch "/api/v1/accounts/#{account.id}/crm/stages/#{proposal.id}",
          params: { name: 'Proposal updated', position: 99 },
          headers: headers,
          as: :json

    expect(response).to have_http_status(:ok)
    expect(proposal.reload).to have_attributes(name: 'Proposal updated', position: original_position)

    post "/api/v1/accounts/#{account.id}/crm/pipelines/#{pipeline.id}/stages",
         params: { name: 'Negotiation', position: 99 },
         headers: headers,
         as: :json

    created_stage = pipeline.stages.find_by!(code: 'negotiation')
    first_terminal_position = pipeline.stages.where(outcome: Crm::Stage::TERMINAL_OUTCOMES).minimum(:position)

    expect(response).to have_http_status(:created)
    expect(created_stage.position).to be < first_terminal_position
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

  it 'only renames standard won and lost stages' do
    stage = account.crm_stages.find_by!(code: 'won')
    original_attributes = stage.slice(:active, :color, :default, :outcome, :position)

    patch "/api/v1/accounts/#{account.id}/crm/stages/#{stage.id}",
          params: {
            active: false,
            color: '#A855F7',
            default: true,
            name: 'Closed Won',
            outcome: 'open',
            position: 99
          },
          headers: headers,
          as: :json

    expect(response).to have_http_status(:ok)
    expect(stage.reload.name).to eq('Closed Won')
    expect(stage.slice(:active, :color, :default, :outcome, :position)).to eq(original_attributes)
  end

  it 'configures closing reasons on standard won and lost stages' do
    stage = account.crm_stages.find_by!(code: 'lost')

    patch "/api/v1/accounts/#{account.id}/crm/stages/#{stage.id}",
          params: {
            closing_reason_options: ['Too expensive', 'Competitor', 'Too expensive'],
            closing_reason_required: true,
            name: 'Closed Lost'
          },
          headers: headers,
          as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('payload', 'name')).to eq('Closed Lost')
    expect(response.parsed_body.dig('payload', 'closing_reason_options')).to eq(['Too expensive', 'Competitor'])
    expect(response.parsed_body.dig('payload', 'closing_reason_required')).to be(false)
    expect(stage.reload.closing_reason_options).to eq(['Too expensive', 'Competitor'])
    expect(stage.closing_reason_required).to be(false)
  end

  it 'configures transition reasons on open stages' do
    stage = account.crm_stages.find_by!(code: 'proposal')

    patch "/api/v1/accounts/#{account.id}/crm/stages/#{stage.id}",
          params: {
            transition_reason_options: ['Needs approval', 'Waiting payment', 'Needs approval'],
            transition_reason_required: true,
            name: 'Proposal sent'
          },
          headers: headers,
          as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('payload', 'name')).to eq('Proposal sent')
    expect(response.parsed_body.dig('payload', 'transition_reason_options')).to eq(['Needs approval', 'Waiting payment'])
    expect(response.parsed_body.dig('payload', 'transition_reason_required')).to be(true)
    expect(stage.reload.transition_reason_options).to eq(['Needs approval', 'Waiting payment'])
    expect(stage.transition_reason_required).to be(true)
  end

  it 'rejects deleting standard won and lost stages' do
    stage = account.crm_stages.find_by!(code: 'lost')

    delete "/api/v1/accounts/#{account.id}/crm/stages/#{stage.id}",
           headers: headers,
           as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body['code']).to eq('STANDARD_STAGE_LOCKED')
    expect(account.crm_stages.exists?(stage.id)).to be(true)
  end

  it 'allows disabling the technical unsorted stage and assigns another open stage as default' do
    stage = account.crm_stages.find_by!(code: 'new')
    fallback_stage = stage.pipeline.stages.find_by!(code: 'qualified')
    original_attributes = stage.slice(:name, :outcome, :position)

    patch "/api/v1/accounts/#{account.id}/crm/stages/#{stage.id}",
          params: {
            active: false,
            default: false,
            name: 'Moved stage',
            outcome: 'lost',
            position: 99
          },
          headers: headers,
          as: :json

    expect(response).to have_http_status(:ok)
    expect(stage.reload).to have_attributes(active: false, default: false)
    expect(stage.slice(:name, :outcome, :position)).to eq(original_attributes)
    expect(fallback_stage.reload).to be_default
  end

  it 'allows disabling a custom default stage and assigns another open stage as default' do
    stage = account.crm_stages.find_by!(code: 'qualified')
    fallback_stage = stage.pipeline.stages.find_by!(code: 'proposal')
    stage.update!(default: true)

    patch "/api/v1/accounts/#{account.id}/crm/stages/#{stage.id}",
          params: { active: false, default: false },
          headers: headers,
          as: :json

    expect(response).to have_http_status(:ok)
    expect(stage.reload).to have_attributes(active: false, default: false)
    expect(fallback_stage.reload).to be_default
  end

  it 'rejects deleting the technical unsorted stage' do
    stage = account.crm_stages.find_by!(code: 'new')

    delete "/api/v1/accounts/#{account.id}/crm/stages/#{stage.id}", headers: headers, as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body['code']).to eq('STANDARD_STAGE_LOCKED')
    expect(account.crm_stages.exists?(stage.id)).to be(true)
  end

  it 'allows duplicate standard colors within the same pipeline' do
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

    expect(response).to have_http_status(:created)
    expect(response.parsed_body.dig('payload', 'color')).to eq(existing_stage.color)
    expect(pipeline.stages.where(color: existing_stage.color).count).to be >= 2
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
