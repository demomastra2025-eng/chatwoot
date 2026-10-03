require 'rails_helper'

RSpec.describe 'CRM stage draft API', type: :request do
  let(:account) { create(:account) }
  let(:administrator) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:headers) { administrator.create_new_auth_token }
  let(:pipeline) { account.crm_pipelines.find_by!(code: 'sales_pipeline') }

  before do
    account.enable_features!('crm_deals')
    Crm::Bootstrap::AccountService.new(account: account).perform
  end

  def open_stage_rows(pipeline)
    Crm::Stage.where(pipeline_id: pipeline.id, outcome: 'open').order(:position, :id).map do |stage|
      {
        id: stage.id,
        name: stage.name,
        color: stage.color,
        active: stage.active,
        default: stage.default,
        transition_reason_options: stage.transition_reason_options,
        transition_reason_required: stage.transition_reason_required,
      }
    end
  end

  def terminal_stage_rows(pipeline)
    Crm::Stage.where(pipeline_id: pipeline.id, outcome: Crm::Stage::TERMINAL_OUTCOMES).order(:position, :id).map do |stage|
      {
        id: stage.id,
        name: stage.name,
        closing_reason_options: stage.closing_reason_options,
        closing_reason_required: stage.closing_reason_required,
      }
    end
  end

  def stage_draft(pipeline)
    {
      deleted_stage_ids: [],
      stages: open_stage_rows(pipeline),
      terminal_stages: terminal_stage_rows(pipeline),
    }
  end

  def submit_stage_draft(draft, auth_headers: headers, pipeline_id: pipeline.id)
    patch "/api/v1/accounts/#{account.id}/crm/pipelines/#{pipeline_id}/stages/batch_update",
          params: draft,
          headers: auth_headers,
          as: :json
  end

  it 'applies stage edits and order together while preserving terminal reason requirements' do
    inactive_stage = create(
      :crm_stage,
      account: account,
      pipeline: pipeline,
      active: false,
      color: '#123456'
    )
    proposal_stage = pipeline.stages.find_by!(code: 'proposal')
    proposal_stage.update!(
      transition_reason_options: ['Waiting for approval'],
      transition_reason_required: true
    )
    lost_stage = pipeline.stages.find_by!(code: 'lost')
    lost_stage.update!(closing_reason_options: ['Price'], closing_reason_required: true)
    original_default = pipeline.stages.find_by!(default: true)
    terminal_order = pipeline.stages.where(outcome: Crm::Stage::TERMINAL_OUTCOMES).order(:position, :id).pluck(:id)
    draft = stage_draft(pipeline)
    draft[:stages].reverse!
    draft[:stages].each { |stage| stage[:default] = false }
    proposal_row = draft[:stages].find { |stage| stage[:id] == proposal_stage.id }
    proposal_row.merge!(
      name: 'Proposal review',
      color: '#2563EB',
      default: true,
      transition_reason_options: ['Waiting for approval', 'Budget confirmed'],
      transition_reason_required: true
    )

    submit_stage_draft(draft)

    expect(response).to have_http_status(:ok)
    expect(
      Crm::Stage.where(pipeline_id: pipeline.id, outcome: 'open').order(:position, :id).pluck(:id)
    ).to eq(draft[:stages].filter_map { |stage| stage[:id] })
    expect(proposal_stage.reload).to have_attributes(
      name: 'Proposal review',
      color: '#2563EB',
      default: true,
      transition_reason_options: ['Waiting for approval', 'Budget confirmed'],
      transition_reason_required: true
    )
    expect(original_default.reload).not_to be_default
    expect(inactive_stage.reload).to have_attributes(active: false)
    expect(lost_stage.reload).to have_attributes(
      closing_reason_options: ['Price'],
      closing_reason_required: true
    )
    expect(
      Crm::Stage.where(outcome: Crm::Stage::TERMINAL_OUTCOMES).order(:position, :id).pluck(:id)
    ).to eq(terminal_order)
    expect(
      Crm::Stage.where(outcome: Crm::Stage::TERMINAL_OUTCOMES).order(:position, :id).pluck(:position)
    ).to eq(((draft[:stages].length + 1)..(draft[:stages].length + 2)).to_a)
  end

  it 'preserves the existing terminal stage order when draft rows arrive reversed' do
    won_stage = pipeline.stages.find_by!(code: 'won')
    lost_stage = pipeline.stages.find_by!(code: 'lost')
    terminal_order = pipeline.stages.where(outcome: Crm::Stage::TERMINAL_OUTCOMES).order(:position, :id).pluck(:id)
    draft = stage_draft(pipeline)
    draft[:terminal_stages].reverse!
    draft[:terminal_stages].find { |stage| stage[:id] == won_stage.id }.merge!(
      name: 'Successful close',
      closing_reason_options: ['Purchase completed'],
      closing_reason_required: true
    )
    draft[:terminal_stages].find { |stage| stage[:id] == lost_stage.id }.merge!(
      name: 'Closed without sale',
      closing_reason_options: ['Chose another supplier'],
      closing_reason_required: true
    )

    submit_stage_draft(draft)

    expect(response).to have_http_status(:ok)
    expect(
      Crm::Stage.where(pipeline_id: pipeline.id, outcome: Crm::Stage::TERMINAL_OUTCOMES).order(:position, :id).pluck(:id)
    ).to eq(terminal_order)
    expect(won_stage.reload).to have_attributes(
      name: 'Successful close',
      closing_reason_options: ['Purchase completed'],
      closing_reason_required: true
    )
    expect(lost_stage.reload).to have_attributes(
      name: 'Closed without sale',
      closing_reason_options: ['Chose another supplier'],
      closing_reason_required: true
    )
  end

  it 'creates and removes open stages inside the same draft contract' do
    original_default = pipeline.stages.find_by!(default: true)
    removable_stage = pipeline.stages.where(outcome: 'open').where.not(id: original_default.id).first
    draft = stage_draft(pipeline)
    draft[:deleted_stage_ids] = [removable_stage.id]
    draft[:stages].reject! { |stage| stage[:id] == removable_stage.id }
    draft[:stages] << {
      name: 'Follow-up',
      color: '#654321',
      active: true,
      default: false,
      transition_reason_options: [],
      transition_reason_required: false,
    }

    submit_stage_draft(draft)

    expect(response).to have_http_status(:ok)
    expect(Crm::Stage.exists?(removable_stage.id)).to be(false)
    follow_up_stage = pipeline.stages.find_by!(name: 'Follow-up')
    expect(follow_up_stage).to have_attributes(
      name: 'Follow-up',
      color: '#654321',
      active: true
    )
    expect(follow_up_stage.code).to eq('follow-up')
    expect(original_default.reload).to be_default
  end

  it 'appends an ordinary stage created after a batch-added open stage' do
    draft = stage_draft(pipeline)
    draft[:stages] << {
      name: 'Follow-up',
      color: '#654321',
      active: true,
      default: false,
      transition_reason_options: [],
      transition_reason_required: false,
    }

    submit_stage_draft(draft)
    expect(response).to have_http_status(:ok)
    batch_added_stage = pipeline.stages.find_by!(name: 'Follow-up')

    post "/api/v1/accounts/#{account.id}/crm/pipelines/#{pipeline.id}/stages",
         params: { name: 'After draft', color: '#654321', active: true },
         headers: headers,
         as: :json

    expect(response).to have_http_status(:created)
    ordinary_stage = pipeline.stages.find_by!(code: 'after_draft')
    open_stages = pipeline.stages.where(outcome: 'open').order(:position, :id)
    terminal_stages = pipeline.stages.where(outcome: Crm::Stage::TERMINAL_OUTCOMES)

    expect(open_stages.pluck(:id).last(2)).to eq([batch_added_stage.id, ordinary_stage.id])
    expect(ordinary_stage.position).to be > batch_added_stage.position
    expect(terminal_stages.minimum(:position)).to be > ordinary_stage.position
  end

  it 'accepts numeric string IDs and maps them to stages in the selected pipeline' do
    draft = stage_draft(pipeline)
    expected_order = draft[:stages].map { |stage| stage[:id].to_s }.reverse
    draft[:stages].reverse!
    draft[:stages].each { |stage| stage[:id] = stage[:id].to_s }
    draft[:terminal_stages].each { |stage| stage[:id] = stage[:id].to_s }

    submit_stage_draft(draft)

    expect(response).to have_http_status(:ok)
    expect(Crm::Stage.where(pipeline_id: pipeline.id, outcome: 'open').order(:position, :id).pluck(:id).map(&:to_s)).to eq(expected_order)
  end

  it 'rejects incomplete, duplicate, terminal, or foreign stage IDs without changing records' do
    original_positions = Crm::Stage.where(pipeline_id: pipeline.id).pluck(:id, :position).to_h
    original_names = Crm::Stage.where(pipeline_id: pipeline.id).pluck(:id, :name).to_h
    other_pipeline = create(:crm_pipeline, account: account, default: false)
    foreign_stage = create(:crm_stage, account: account, pipeline: other_pipeline, color: '#654321')
    valid_draft = stage_draft(pipeline)
    invalid_drafts = [
      valid_draft.deep_dup.tap { |draft| draft[:stages].pop },
      valid_draft.deep_dup.tap do |draft|
        draft[:stages][1][:id] = draft[:stages][0][:id]
      end,
      valid_draft.deep_dup.tap do |draft|
        draft[:stages][0][:id] = pipeline.stages.find_by!(code: 'won').id
      end,
      valid_draft.deep_dup.tap do |draft|
        draft[:stages][0][:id] = foreign_stage.id
      end,
    ]

    invalid_drafts.each do |draft|
      submit_stage_draft(draft)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body['code']).to eq('INVALID_STAGE_ORDER')
      expect(Crm::Stage.where(pipeline_id: pipeline.id).pluck(:id, :position).to_h).to eq(original_positions)
      expect(Crm::Stage.where(pipeline_id: pipeline.id).pluck(:id, :name).to_h).to eq(original_names)
    end
  end

  it 'rolls back every edit when a required transition reason has no options' do
    proposal_stage = pipeline.stages.find_by!(code: 'proposal')
    original_attributes = proposal_stage.attributes
    draft = stage_draft(pipeline)
    proposal_row = draft[:stages].find { |stage| stage[:id] == proposal_stage.id }
    proposal_row.merge!(name: 'Should roll back', transition_reason_required: true, transition_reason_options: [])

    submit_stage_draft(draft)

    expect(response).to have_http_status(:unprocessable_content)
    expect(proposal_stage.reload.attributes).to eq(original_attributes)
  end

  it 'rolls back open-stage edits when a terminal closing-reason draft is invalid' do
    proposal_stage = pipeline.stages.find_by!(code: 'proposal')
    lost_stage = pipeline.stages.find_by!(code: 'lost')
    proposal_attributes = proposal_stage.attributes
    lost_attributes = lost_stage.attributes
    draft = stage_draft(pipeline)
    draft[:stages].find { |stage| stage[:id] == proposal_stage.id }[:name] = 'Must roll back'
    draft[:terminal_stages].find { |stage| stage[:id] == lost_stage.id }.merge!(
      closing_reason_required: true,
      closing_reason_options: []
    )

    submit_stage_draft(draft)

    expect(response).to have_http_status(:unprocessable_content)
    expect(proposal_stage.reload.attributes).to eq(proposal_attributes)
    expect(lost_stage.reload.attributes).to eq(lost_attributes)
  end

  it 'moves the default to an active fallback when the current default is removed' do
    default_stage = pipeline.stages.find_by!(default: true)
    draft = stage_draft(pipeline)
    draft[:deleted_stage_ids] = [default_stage.id]
    draft[:stages].reject! { |stage| stage[:id] == default_stage.id }
    draft[:stages].each { |stage| stage[:default] = false }

    submit_stage_draft(draft)

    expect(response).to have_http_status(:ok)
    expect(Crm::Stage.exists?(default_stage.id)).to be(false)
    expect(pipeline.stages.active.where(outcome: 'open', default: true).count).to eq(1)
  end

  it 'moves the default to an active fallback when the current default is deactivated' do
    default_stage = pipeline.stages.find_by!(default: true)
    draft = stage_draft(pipeline)
    draft[:stages].each { |stage| stage[:default] = false }
    draft[:stages].find { |stage| stage[:id] == default_stage.id }.merge!(
      active: false,
      default: false
    )

    submit_stage_draft(draft)

    expect(response).to have_http_status(:ok)
    expect(default_stage.reload).to have_attributes(active: false)
    expect(default_stage).not_to be_default
    expect(pipeline.stages.active.where(outcome: 'open', default: true).count).to eq(1)
  end

  it 'rejects a draft with no active open fallback and rolls back the changes' do
    original_positions = Crm::Stage.where(pipeline_id: pipeline.id).pluck(:id, :position).to_h
    original_default = pipeline.stages.find_by!(default: true)
    draft = stage_draft(pipeline)
    draft[:stages].each do |stage|
      stage[:active] = false
      stage[:default] = false
    end

    submit_stage_draft(draft)

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body['code']).to eq('DEFAULT_STAGE_REQUIRES_FALLBACK')
    expect(original_default.reload).to be_default
    expect(Crm::Stage.where(pipeline_id: pipeline.id).pluck(:id, :position).to_h).to eq(original_positions)
  end

  it 'requires CRM settings access and scopes stage drafts to the account' do
    draft = stage_draft(pipeline)
    submit_stage_draft(draft, auth_headers: agent.create_new_auth_token)
    expect(response).to have_http_status(:unauthorized)

    other_account = create(:account)
    other_account.enable_features!('crm_deals')
    Crm::Bootstrap::AccountService.new(account: other_account).perform
    other_pipeline = other_account.crm_pipelines.find_by!(code: 'sales_pipeline')
    submit_stage_draft(draft, pipeline_id: other_pipeline.id)
    expect(response).to have_http_status(:not_found)
  end

  it 'reports terminal and deal blockers without mutating protected stages' do
    terminal_stage = pipeline.stages.find_by!(code: 'won')
    original_attributes = terminal_stage.attributes
    get "/api/v1/accounts/#{account.id}/crm/stages/#{terminal_stage.id}/deletion_check",
        headers: headers,
        as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('payload', 'can_delete')).to be(false)
    expect(response.parsed_body.dig('payload', 'block_reason')).to eq('STANDARD_STAGE_LOCKED')
    expect(terminal_stage.reload.attributes).to eq(original_attributes)

    stage = create(:crm_stage, account: account, pipeline: pipeline, color: '#654321')
    create(:crm_deal, account: account, pipeline: pipeline, stage: stage)
    get "/api/v1/accounts/#{account.id}/crm/stages/#{stage.id}/deletion_check",
        headers: headers,
        as: :json

    expect(response.parsed_body.dig('payload', 'can_delete')).to be(false)
    expect(response.parsed_body.dig('payload', 'deal_count')).to eq(1)
    expect(response.parsed_body.dig('payload', 'block_reason')).to eq('STAGE_HAS_DEALS')
  end
end
