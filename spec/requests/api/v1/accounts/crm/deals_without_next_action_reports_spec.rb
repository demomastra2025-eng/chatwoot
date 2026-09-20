require 'rails_helper'

RSpec.describe 'CRM Deals Without Next Action Reports API', type: :request do
  let(:account) { create(:account, settings: { 'workspace_timezone' => 'Asia/Almaty' }) }
  let(:viewer) { create(:user, :administrator, account: account) }
  let(:headers) { viewer.create_new_auth_token }
  let(:aggregate_path) { "/api/v1/accounts/#{account.id}/crm/reports/deals_without_next_action" }
  let(:details_path) { "/api/v1/accounts/#{account.id}/crm/reports/deals_without_next_action_details" }
  let(:pipeline) { create(:crm_pipeline, account: account) }
  let(:stage) { create(:crm_stage, account: account, pipeline: pipeline) }
  let(:open_status) { create(:crm_task_status, account: account, category: 'open') }

  before do
    account.enable_features!('crm_deals', 'crm_tasks')
  end

  def enable_enforced_access!
    AccessControl::LegacyRoleAssigner.call(account: account, apply: true)
    AccessControl::ModeTransition.call(account: account, to: :shadow)
    AccessControl::ModeTransition.call(account: account, to: :enforced)
  end

  def set_scope(resource, capability, scope)
    grants = viewer.account_users.find_by!(account: account).access_role.grants
    grant = grants.find_or_initialize_by(account: account, resource: resource, capability: capability)
    grant.update!(access_scope: scope)
  end

  it 'returns parity-identical aggregate and stable paginated Deal-only details' do # rubocop:disable RSpec/MultipleExpectations
    first = create(:crm_deal, account: account, pipeline: pipeline, stage: stage, title: 'First')
    second = create(:crm_deal, account: account, pipeline: pipeline, stage: stage, title: 'Second')

    get aggregate_path, headers: headers, as: :json
    aggregate = response.parsed_body
    expect(response).to have_http_status(:ok)

    get details_path, params: { page: 1, per_page: 1 }, headers: headers, as: :json
    first_page = response.parsed_body
    get details_path, params: { page: 2, per_page: 1 }, headers: headers, as: :json
    second_page = response.parsed_body

    expect(aggregate.dig('payload', 'rows')).to eq([{ 'no_action_count' => 2 }])
    expect(first_page.dig('payload', 'rows').pluck('deal_id')).to eq([first.id])
    expect(second_page.dig('payload', 'rows').pluck('deal_id')).to eq([second.id])
    expect(first_page.dig('meta', 'total_count')).to eq(2)
    expect(aggregate.dig('meta', 'query_fingerprint')).to eq(first_page.dig('meta', 'query_fingerprint'))
    expect(first_page.to_json).not_to include('task_id', 'due_at', 'due_on')
    expect(aggregate['meta']).to include(
      'metric_kind' => 'current_snapshot',
      'reliability' => 'exact',
      'timezone' => 'Asia/Almaty',
      'definition_version' => 1,
      'temporal_definition' => 'exact_current_snapshot_not_historical'
    )
    expect(Time.iso8601(aggregate.dig('meta', 'generated_at_local')).utc)
      .to be_within(1.second).of(Time.iso8601(aggregate.dig('meta', 'generated_at')))
  end

  it 'applies Deal and Task view intersect view_reports scopes independently' do
    teammate = create(:user, account: account)
    outsider = create(:user, account: account)
    team = create(:team, account: account)
    create(:team_member, team: team, user: viewer)
    own_deal = create(:crm_deal, account: account, pipeline: pipeline, stage: stage, owner: viewer)
    team_deal = create(:crm_deal, account: account, pipeline: pipeline, stage: stage, owner: teammate, team: team)
    hidden_deal = create(:crm_deal, account: account, pipeline: pipeline, stage: stage, owner: outsider)
    create(:crm_task, account: account, deal: team_deal, status: open_status, assignee: teammate, team: team)
    create(:crm_task, account: account, deal: hidden_deal, status: open_status, assignee: outsider)
    enable_enforced_access!

    set_scope('deals', 'view', 'all')
    set_scope('deals', 'view_reports', 'team')
    set_scope('tasks', 'view', 'own')
    set_scope('tasks', 'view_reports', 'all')
    get details_path, headers: headers, as: :json
    expect(response.parsed_body.dig('payload', 'rows').pluck('deal_id')).to contain_exactly(own_deal.id, team_deal.id)

    set_scope('tasks', 'view', 'team')
    get aggregate_path, headers: headers, as: :json
    expect(response.parsed_body.dig('payload', 'rows')).to eq([{ 'no_action_count' => 1 }])

    set_scope('tasks', 'view_reports', 'none')
    get aggregate_path, headers: headers, as: :json
    expect(response).to have_http_status(:unauthorized)

    set_scope('tasks', 'view_reports', 'all')
    set_scope('deals', 'view_reports', 'none')
    get aggregate_path, headers: headers, as: :json
    expect(response).to have_http_status(:unauthorized)
  end

  it 'treats waiting and every kept open task schedule as an action but ignores terminal or archived records' do
    waiting = create(:crm_deal, account: account, pipeline: pipeline, stage: stage, waiting_until: 1.hour.ago,
                                waiting_started_at: 1.day.ago, waiting_reason: 'Expired wait')
    timed = create(:crm_deal, account: account, pipeline: pipeline, stage: stage)
    all_day = create(:crm_deal, account: account, pipeline: pipeline, stage: stage)
    unscheduled = create(:crm_deal, account: account, pipeline: pipeline, stage: stage)
    terminal_only = create(:crm_deal, account: account, pipeline: pipeline, stage: stage)
    archived_task_only = create(:crm_deal, account: account, pipeline: pipeline, stage: stage)
    create(:crm_task, account: account, deal: timed, status: open_status, due_at: 1.hour.from_now)
    in_progress_status = create(:crm_task_status, account: account, category: 'in_progress')
    create(:crm_task, account: account, deal: all_day, status: in_progress_status, all_day: true, due_on: Time.zone.today)
    create(:crm_task, account: account, deal: unscheduled, status: open_status)
    done_status = create(:crm_task_status, account: account, category: 'done')
    create(:crm_task, account: account, deal: terminal_only, status: done_status)
    create(:crm_task, account: account, deal: archived_task_only, status: open_status, archived_at: Time.current)
    create(:crm_deal, account: account, pipeline: pipeline, stage: stage, closed_at: Time.current)
    create(:crm_deal, account: account, pipeline: pipeline, stage: stage, archived_at: Time.current)

    get details_path, headers: headers, as: :json

    ids = response.parsed_body.dig('payload', 'rows').pluck('deal_id')
    expect(ids).to contain_exactly(terminal_only.id, archived_task_only.id)
    expect(ids).not_to include(waiting.id, timed.id, all_day.id, unscheduled.id)
  end

  it 'validates tenant-safe filters and keeps aggregate and details fingerprints identical' do
    owner = create(:user, account: account)
    team = create(:team, account: account)
    matching = create(:crm_deal, account: account, pipeline: pipeline, stage: stage, owner: owner, team: team)
    create(:crm_deal, account: account)
    filters = { pipeline_id: pipeline.id, stage_id: stage.id, owner_id: owner.id, team_id: team.id }

    get aggregate_path, params: filters, headers: headers, as: :json
    aggregate = response.parsed_body
    get details_path, params: filters, headers: headers, as: :json
    details = response.parsed_body

    expect(aggregate.dig('payload', 'rows')).to eq([{ 'no_action_count' => 1 }])
    expect(details.dig('payload', 'rows').pluck('deal_id')).to eq([matching.id])
    expect(aggregate.dig('meta', 'query_fingerprint')).to eq(details.dig('meta', 'query_fingerprint'))

    foreign_owner = create(:user, account: create(:account))
    get aggregate_path, params: { owner_id: foreign_owner.id }, headers: headers, as: :json
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body).to include('code' => 'INVALID_REPORT_QUERY', 'error' => 'owner_id is invalid')
  end

  it 'requires authentication, both report capabilities, and both CRM feature gates' do
    get aggregate_path, as: :json
    expect(response).to have_http_status(:unauthorized)

    account.disable_features!('crm_tasks')
    get aggregate_path, headers: headers, as: :json
    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body['code']).to eq('FEATURE_DISABLED')
  end
end
