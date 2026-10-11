require 'rails_helper'

RSpec.describe 'Atomic CRM pipeline Save', type: :request do
  let(:account) { create(:account) }
  let(:administrator) { create(:user, account: account, role: :administrator) }
  let(:headers) { administrator.create_new_auth_token }
  let(:pipeline) { account.crm_pipelines.find_by!(code: 'sales_pipeline') }
  let(:path) { "/api/v1/accounts/#{account.id}/crm/pipelines/#{pipeline.id}" }

  before do
    account.enable_features!('crm_deals')
    Crm::Bootstrap::AccountService.new(account: account).perform
  end

  def draft
    {
      name: 'Updated funnel', auto_create_deal_on_channel_contact: true,
      restrict_backward_move: true, restrict_stage_skipping: false, allow_stage_rule_override: false,
      stages: pipeline.stages.where(outcome: 'open').where.not(code: Crm::Stage::TECHNICAL_STAGE_CODES).map do |stage|
        { id: stage.id, name: stage.name, color: stage.color, active: stage.active }
      end,
      deleted_stage_ids: [],
      terminal_stages: pipeline.stages.where(outcome: Crm::Stage::TERMINAL_OUTCOMES).map do |stage|
        { id: stage.id, name: stage.name, closing_reason_options: stage.closing_reason_options,
          closing_reason_required: stage.closing_reason_required }
      end,
      technical_stage: { id: pipeline.stages.find_by!(code: 'new').id, active: true },
      appointment_automation: { auto_create_deals: false, enabled: false, auto_create_from_calendar: true }
    }
  end

  def submit(attributes)
    patch path, params: attributes, headers: headers, as: :json
  end

  it 'saves the complete funnel and resolves new-stage references for channel creation and appointment rules together', :aggregate_failures do
    attrs = draft
    attrs[:stages].reverse!
    attrs[:stages] << {
      client_id: 'draft-stage-1', name: 'Review', color: '#123456', active: true,
      field_requirements: [{ field_key: 'description', required: true, validation: { min_length: 10 }, role_exemptions: ['agent'] }]
    }
    attrs[:auto_create_stage_id] = 'draft-stage-1'
    attrs[:appointment_automation][:rules] = [{ stage_id: 'draft-stage-1', scope: 'any', conditions: ['scheduled'] }]
    lost = pipeline.stages.find_by!(code: 'lost')
    attrs[:terminal_stages].find { |row| row[:id] == lost.id }.merge!(closing_reason_options: ['Price'], closing_reason_required: true)

    submit(attrs)

    expect(response).to have_http_status(:ok)
    saved = pipeline.reload
    created_stage = saved.stages.find_by!(name: 'Review')
    expect(saved).to have_attributes(name: 'Updated funnel', restrict_backward_move: true, auto_create_deal_on_channel_contact: true)
    expect(created_stage).to be_default
    expect(saved.appointment_automation).to include('auto_create_deals' => false, 'auto_create_from_calendar' => true)
    expect(saved.appointment_automation['rules'].first['stage_id']).to eq(created_stage.id)
    expect(created_stage.field_requirements.first).to have_attributes(
      field_key: 'description', required: true, validation: { 'min_length' => 10 }, role_exemptions: ['agent']
    )
    expect(lost.reload).to have_attributes(closing_reason_options: ['Price'], closing_reason_required: true)
    expect(response.parsed_body.dig('payload', 'appointment_automation', 'auto_create_deals')).to be false
    expect(response.parsed_body.dig('payload', 'stages').pluck('id')).to include(created_stage.id)
  end

  it 'rolls back stage edits, source ownership, channel settings and pipeline attributes when a later rule is invalid' do
    other = create(:crm_pipeline, account: account, appointment_automation: { auto_create_from_calendar: true })
    before_pipeline = pipeline.attributes
    before_stages = pipeline.stages.order(:id).map(&:attributes)
    before_other = other.attributes
    attrs = draft
    attrs[:stages].first[:name] = 'Must roll back'
    attrs[:appointment_automation].merge!(auto_create_deals: true, rules: [{ stage_id: 0, scope: 'any', conditions: ['scheduled'] }])

    submit(attrs)

    expect(response).to have_http_status(:unprocessable_content)
    expect(pipeline.reload.attributes).to eq(before_pipeline)
    expect(pipeline.stages.order(:id).map(&:attributes)).to eq(before_stages)
    expect(other.reload.attributes).to eq(before_other)
  end

  it 'rolls back every edit when the draft deletes an occupied stage' do
    occupied = pipeline.stages.find_by!(code: 'proposal')
    create(:crm_deal, account: account, pipeline: pipeline, stage: occupied)
    attrs = draft
    attrs[:deleted_stage_ids] = [occupied.id]
    attrs[:stages].reject! { |row| row[:id] == occupied.id }
    original_name = pipeline.name
    original_stage_names = pipeline.stages.pluck(:id, :name).to_h

    submit(attrs)

    expect(response).to have_http_status(:unprocessable_content)
    expect(pipeline.reload.name).to eq(original_name)
    expect(pipeline.auto_create_deal_on_channel_contact).to be false
    expect(pipeline.stages.pluck(:id, :name).to_h).to eq(original_stage_names)
    expect(Crm::Deal.where(stage_id: occupied.id)).to exist
  end

  it 'rejects foreign stage references and duplicate client IDs without saving any draft changes' do
    foreign = create(:crm_stage)
    attrs = draft
    attrs[:auto_create_stage_id] = foreign.id
    submit(attrs)
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body['code']).to eq('INVALID_AUTO_CREATE_STAGE')
    expect(pipeline.reload.auto_create_deal_on_channel_contact).to be false

    attrs = draft
    2.times { attrs[:stages] << { client_id: 'draft-stage-1', name: 'Duplicate', active: true } }
    expect { submit(attrs) }.not_to change(Crm::Stage, :count)
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body['code']).to eq('INVALID_STAGE_DRAFT')
  end

  it 'saves ordering and default pipeline changes in the same mutation', :aggregate_failures do
    other = create(:crm_pipeline, account: account)
    attrs = draft.merge(default: false, pipeline_order: [other.id, pipeline.id])

    submit(attrs)

    expect(response).to have_http_status(:ok)
    expect(account.crm_pipelines.active.ordered.pluck(:id)).to eq([other.id, pipeline.id])
    expect(other.reload).to have_attributes(default: true, position: 10)
    expect(pipeline.reload).to have_attributes(default: false, position: 20)
    expect(response.parsed_body.fetch('pipelines').find { |row| row['id'] == other.id }).to include('default' => true, 'position' => 10)
  end

  it 'archives a default pipeline with its full draft and publishes the replacement default in the same response' do
    other = create(:crm_pipeline, account: account)

    submit(draft.merge(active: false, default: true))

    expect(response).to have_http_status(:ok)
    expect(pipeline.reload).to have_attributes(active: false, default: false)
    expect(other.reload).to be_default
    expect(response.parsed_body.fetch('pipelines').find { |row| row['id'] == other.id }).to include('default' => true)
  end

  it 'rolls back source settings and other funnels when an incomplete or foreign pipeline order is submitted' do
    other = create(:crm_pipeline, account: account, appointment_automation: { auto_create_from_calendar: true })
    foreign = create(:crm_pipeline)
    before_other = other.attributes
    before_pipeline = pipeline.attributes
    attrs = draft
    attrs[:appointment_automation][:auto_create_deals] = true
    attrs[:pipeline_order] = [foreign.id, pipeline.id]

    submit(attrs)

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body['code']).to eq('INVALID_PIPELINE_ORDER')
    expect(other.reload.attributes).to eq(before_other)
    expect(pipeline.reload.attributes).to eq(before_pipeline)
  end

  it 'omits a removed channel target while OFF and keeps a retained active open fallback' do
    removable = pipeline.stages.find_by!(code: 'proposal')
    removable.update!(default: true)
    attrs = draft.merge(auto_create_deal_on_channel_contact: false)
    attrs[:deleted_stage_ids] = [removable.id]
    attrs[:stages].reject! { |row| row[:id] == removable.id }

    submit(attrs)

    expect(response).to have_http_status(:ok)
    expect(pipeline.reload.stages.active.where(outcome: 'open', default: true)).to exist
    expect(Crm::Stage.exists?(removable.id)).to be false
  end

  it 'keeps the simple pipeline PATCH compatible when no stage draft is supplied' do
    original_ids = pipeline.stages.pluck(:id)

    submit(name: 'Simple edit', appointment_automation: { auto_create_deals: false })

    expect(response).to have_http_status(:ok)
    expect(pipeline.reload.name).to eq('Simple edit')
    expect(pipeline.stages.pluck(:id)).to eq(original_ids)
  end
end
