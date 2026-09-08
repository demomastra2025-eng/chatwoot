require 'rails_helper'

RSpec.describe 'CRM Deal lifecycle commands', type: :request do
  let(:account) { create(:account) }
  let(:administrator) { create(:user, account: account, role: :administrator) }
  let(:headers) { administrator.create_new_auth_token }
  let(:path) { "/api/v1/accounts/#{account.id}/crm/deals" }
  let(:pipeline) { account.crm_pipelines.find_by!(code: 'sales_pipeline') }
  let(:open_stage) { pipeline.stages.find_by!(code: 'new') }
  let(:won_stage) { pipeline.stages.find_by!(code: 'won') }
  let(:lost_stage) { pipeline.stages.find_by!(code: 'lost') }
  let(:deal) { create(:crm_deal, account: account, pipeline: pipeline, stage: open_stage) }

  before do
    account.enable_features!('crm_deals')
    account.enable_features!('crm_tasks')
    Crm::Bootstrap::AccountService.new(account: account).perform
  end

  it 'requires a Lost reason only when the target stage toggle is enabled' do
    lost_stage.update!(closing_reason_options: ['Competitor'], closing_reason_required: true)

    post "#{path}/#{deal.id}/close_lost",
         params: { lock_version: deal.lock_version, idempotency_key: 'lost-1' }, headers: headers, as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body['code']).to eq('VALIDATION_ERROR')

    lost_stage.update!(closing_reason_required: false)
    post "#{path}/#{deal.id}/close_lost",
         params: { lock_version: deal.reload.lock_version, idempotency_key: 'lost-2' }, headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    event = deal.events.where(event_type: 'deal_stage_changed').last
    expect(event.meta).to include(
      'command_type' => 'close_lost',
      'from_pipeline_id' => pipeline.id,
      'from_stage_id' => open_stage.id,
      'closing_reasons' => []
    )
  end

  it 'returns the previous result for an identical command key and rejects different parameters' do
    payload = { stage_id: won_stage.id, lock_version: deal.lock_version, idempotency_key: 'close-1' }
    post "#{path}/#{deal.id}/close_won", params: payload, headers: headers, as: :json
    resulting_version = response.parsed_body.dig('payload', 'lock_version')

    post "#{path}/#{deal.id}/close_won", params: payload, headers: headers, as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('payload', 'lock_version')).to eq(resulting_version)

    post "#{path}/#{deal.id}/close_lost",
         params: payload.merge(stage_id: lost_stage.id), headers: headers, as: :json
    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body['code']).to eq('IDEMPOTENCY_KEY_REUSED')
  end

  it 'reopens a closed deal and keeps the previous terminal visit as history', :aggregate_failures do
    task = create(:crm_task, account: account, deal: deal)
    post "#{path}/#{deal.id}/close_won",
         params: { lock_version: deal.lock_version, idempotency_key: 'won-1' }, headers: headers, as: :json
    closed_visit = deal.reload.stage_visits.find_by!(stage_id: won_stage.id)
    close_event = deal.events.where(event_type: 'deal_stage_changed').last
    task_cancelled_event = task.events.where(event_type: 'task_cancelled').last

    expect(task.reload.archived_at).to be_nil
    expect(task.cancelled_at).to be_present
    expect(task.cancelled_by_id).to eq(administrator.id)
    expect(task.cancellation_reason).to eq('deal_closed')
    expect(task.status.category).to eq('cancelled')
    expect(task.completed_at).to be_nil
    expect(task_cancelled_event.correlation_id).to eq(close_event.correlation_id)

    post "#{path}/#{deal.id}/reopen",
         params: { stage_id: open_stage.id, lock_version: deal.lock_version, idempotency_key: 'reopen-1' }, headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    expect(deal.reload).to have_attributes(stage_id: open_stage.id, closed_at: nil, closing_reasons: [])
    expect(closed_visit.reload.exited_at).to be_present
    expect(task.reload.archived_at).to be_nil
    expect(task.cancelled_at).to be_present
  end

  it 'undoes only the latest recent transition by creating a compensating transition' do
    post "#{path}/#{deal.id}/close_won",
         params: { lock_version: deal.lock_version, idempotency_key: 'won-undo' }, headers: headers, as: :json
    source_event = deal.events.where(event_type: 'deal_stage_changed').last

    post "#{path}/#{deal.id}/undo_transition",
         params: { event_id: source_event.id, lock_version: deal.reload.lock_version, idempotency_key: 'undo-1' },
         headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    undo_event = deal.events.where(event_type: 'deal_stage_changed').last
    expect(deal.reload.stage_id).to eq(open_stage.id)
    expect(undo_event).to have_attributes(causation_id: source_event.correlation_id)
    expect(undo_event.meta['command_type']).to eq('undo_transition')
  end

  it 'reorders without opening a new stage visit and returns current snapshot on stale version' do
    Crm::StageVisits::Tracker.ensure_initial!(deal: deal, correlation_id: SecureRandom.uuid)
    visit_count = deal.stage_visits.count

    post "#{path}/#{deal.id}/reorder",
         params: { position: 2, lock_version: deal.lock_version, idempotency_key: 'reorder-1' }, headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    expect(deal.reload.stage_visits.count).to eq(visit_count)

    post "#{path}/#{deal.id}/reorder",
         params: { position: 3, lock_version: 0, idempotency_key: 'reorder-2' }, headers: headers, as: :json
    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body.dig('details', 'current')).to include(
      'id' => deal.id,
      'lock_version' => deal.reload.lock_version,
      'stage_id' => open_stage.id
    )
  end
end
