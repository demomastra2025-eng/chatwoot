require 'rails_helper'

RSpec.describe 'CRM Tasks enforced access boundary', type: :request do
  let(:account) { create(:account) }
  let(:viewer) { create(:user, account: account, role: :agent) }
  let(:headers) { viewer.create_new_auth_token }
  let(:path) { "/api/v1/accounts/#{account.id}/crm/tasks" }

  before do
    account.enable_features!('crm_tasks')
    Crm::Bootstrap::AccountService.new(account: account).perform
    AccessControl::LegacyRoleAssigner.call(account: account, apply: true)
    AccessControl::ModeTransition.call(account: account, to: :shadow)
    AccessControl::ModeTransition.call(account: account, to: :enforced)
  end

  it 'allows team tasks while denying deals for a tasks-only Lead' do
    account.enable_features!('crm_deals')
    grants = viewer.account_users.find_by!(account: account).access_role.grants
    grants.find_by!(resource: 'tasks', capability: 'view').update!(access_scope: 'team')
    grants.find_by!(resource: 'deals', capability: 'view').update!(access_scope: 'none')
    team = create(:team, account: account)
    create(:team_member, team: team, user: viewer)
    teammate = create(:user, account: account)
    team_task = create(:crm_task, account: account, team: team, assignee: teammate)

    get path, headers: headers, as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch('payload').pluck('id')).to include(team_task.id)

    get "/api/v1/accounts/#{account.id}/crm/deals", headers: headers, as: :json
    expect(response).to have_http_status(:unauthorized)
  end

  it 'serves granted team tasks while Deals is disabled despite a deal view grant' do
    account.disable_features!('crm_deals')
    grants = viewer.account_users.find_by!(account: account).access_role.grants
    grants.find_by!(resource: 'tasks', capability: 'view').update!(access_scope: 'team')
    grants.find_by!(resource: 'deals', capability: 'view').update!(access_scope: 'team')
    team = create(:team, account: account)
    create(:team_member, team: team, user: viewer)
    teammate = create(:user, account: account)
    team_task = create(:crm_task, account: account, team: team, assignee: teammate)

    get path, headers: headers, as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch('payload').pluck('id')).to include(team_task.id)

    get "/api/v1/accounts/#{account.id}/crm/deals", headers: headers, as: :json
    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body.fetch('code')).to eq('FEATURE_DISABLED')
  end

  it 'refuses to link a new task to a deal when Deals is disabled' do
    account.disable_features!('crm_deals')
    deal = create(:crm_deal, account: account, owner: viewer)

    expect do
      post path, params: { title: 'Unreachable linked task', deal_id: deal.id, assignee_id: viewer.id },
                 headers: headers, as: :json
    end.not_to change(account.crm_tasks, :count)
    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body.fetch('code')).to eq('FEATURE_DISABLED')
  end

  it 'refuses to link a new task to a deal outside the actor view grant' do
    account.enable_features!('crm_deals')
    grants = viewer.account_users.find_by!(account: account).access_role.grants
    grants.find_by!(resource: 'deals', capability: 'view').update!(access_scope: 'none')
    deal = create(:crm_deal, account: account, owner: viewer)

    expect do
      post path, params: { title: 'Denied linked task', deal_id: deal.id, assignee_id: viewer.id },
                 headers: headers, as: :json
    end.not_to change(account.crm_tasks, :count)
    expect(response).to have_http_status(:unauthorized)
  end

  it 'keeps an existing task deal link when editing its fields without Deals access' do
    account.disable_features!('crm_deals')
    deal = create(:crm_deal, account: account, owner: viewer)
    task = create(:crm_task, account: account, assignee: viewer, deal: deal, context_kind: 'sales')

    patch "#{path}/#{task.id}",
          params: { title: 'Edited linked task', deal_id: deal.id, lock_version: task.lock_version },
          headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    expect(task.reload).to have_attributes(title: 'Edited linked task', deal_id: deal.id)
  end

  it 'does not bypass task assignment grants by inheriting a different team from a linked deal' do
    account.enable_features!('crm_deals')
    grants = viewer.account_users.find_by!(account: account).access_role.grants
    grants.find_by!(resource: 'deals', capability: 'view').update!(access_scope: 'all')
    grants.find_by!(resource: 'tasks', capability: 'update_fields').update!(access_scope: 'own')
    grants.find_by!(resource: 'tasks', capability: 'assign').update!(access_scope: 'none')
    other_team = create(:team, account: account)
    deal = create(:crm_deal, account: account, owner: viewer, team: other_team)
    task = create(:crm_task, account: account, assignee: viewer, team: nil, context_kind: 'personal')

    patch "#{path}/#{task.id}",
          params: { deal_id: deal.id, context_kind: 'sales', lock_version: task.lock_version },
          headers: headers, as: :json

    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body.fetch('code')).to eq('TASK_ASSIGNMENT_FORBIDDEN')
    expect(task.reload).to have_attributes(deal_id: nil, team_id: nil, context_kind: 'personal')

    post "#{path}/#{task.id}/save_form",
         params: { deal_id: deal.id, context_kind: 'sales', lock_version: task.lock_version,
                   idempotency_key: SecureRandom.uuid },
         headers: headers, as: :json

    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body.fetch('code')).to eq('TASK_ASSIGNMENT_FORBIDDEN')
    expect(task.reload).to have_attributes(deal_id: nil, team_id: nil, context_kind: 'personal')
  end

  it 'allows linking a deal without task assignment rights when the existing team does not change' do
    account.enable_features!('crm_deals')
    grants = viewer.account_users.find_by!(account: account).access_role.grants
    grants.find_by!(resource: 'deals', capability: 'view').update!(access_scope: 'all')
    grants.find_by!(resource: 'tasks', capability: 'update_fields').update!(access_scope: 'own')
    grants.find_by!(resource: 'tasks', capability: 'assign').update!(access_scope: 'none')
    team = create(:team, account: account)
    create(:team_member, team: team, user: viewer)
    deal = create(:crm_deal, account: account, owner: viewer, team: team)
    task = create(:crm_task, account: account, assignee: viewer, team: team, context_kind: 'personal')

    patch "#{path}/#{task.id}",
          params: { deal_id: deal.id, context_kind: 'sales', lock_version: task.lock_version },
          headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    expect(task.reload).to have_attributes(deal_id: deal.id, team_id: team.id, context_kind: 'sales')
  end

  it 'syncs inherited task teams on an authorized deal transfer without a task assignment grant' do
    account.enable_features!('crm_deals')
    grants = viewer.account_users.find_by!(account: account).access_role.grants
    grants.find_by!(resource: 'deals', capability: 'view').update!(access_scope: 'all')
    grants.find_by!(resource: 'deals', capability: 'update_fields').update!(access_scope: 'all')
    grants.find_by!(resource: 'deals', capability: 'assign').update!(access_scope: 'all')
    grants.find_by!(resource: 'tasks', capability: 'assign').update!(access_scope: 'none')
    old_team = create(:team, account: account)
    new_team = create(:team, account: account)
    [old_team, new_team].each { |team| create(:team_member, team: team, user: viewer) }
    deal = create(:crm_deal, account: account, owner: viewer, team: old_team)
    task = create(:crm_task, account: account, assignee: viewer, team: old_team, deal: deal, context_kind: 'sales')

    patch "/api/v1/accounts/#{account.id}/crm/deals/#{deal.id}",
          params: { team_id: new_team.id, lock_version: deal.lock_version }, headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    expect(deal.reload.team).to eq(new_team)
    expect(task.reload.team).to eq(new_team)
  end

  it 'keeps historical linked task teams editable after a deal transfer without task assignment rights' do
    account.enable_features!('crm_deals')
    grants = viewer.account_users.find_by!(account: account).access_role.grants
    %w[view update_fields assign].each do |capability|
      grants.find_by!(resource: 'deals', capability: capability).update!(access_scope: 'all')
    end
    grants.find_by!(resource: 'tasks', capability: 'update_fields').update!(access_scope: 'own')
    grants.find_by!(resource: 'tasks', capability: 'assign').update!(access_scope: 'none')
    old_team = create(:team, account: account)
    new_team = create(:team, account: account)
    deal = create(:crm_deal, account: account, owner: viewer, team: old_team)
    done_status = create(:crm_task_status, account: account, category: 'done')
    completed = create(:crm_task, account: account, assignee: viewer, team: old_team, deal: deal,
                                  context_kind: 'sales', status: done_status)
    archived = create(:crm_task, account: account, assignee: viewer, team: old_team, deal: deal,
                                 context_kind: 'sales', archived_at: Time.current)

    patch "/api/v1/accounts/#{account.id}/crm/deals/#{deal.id}",
          params: { team_id: new_team.id, lock_version: deal.lock_version }, headers: headers, as: :json
    expect(response).to have_http_status(:ok)
    expect(completed.reload.team).to eq(old_team)
    expect(archived.reload.team).to eq(old_team)

    patch "#{path}/#{completed.id}",
          params: { title: 'Updated completed', context_kind: 'sales', deal_id: deal.id,
                    lock_version: completed.lock_version }, headers: headers, as: :json
    expect(response).to have_http_status(:ok)
    expect(completed.reload).to have_attributes(title: 'Updated completed', team_id: old_team.id)

    post "#{path}/#{archived.id}/save_form",
         params: { title: 'Updated archived', context_kind: 'sales', deal_id: deal.id,
                   lock_version: archived.lock_version, idempotency_key: SecureRandom.uuid },
         headers: headers, as: :json
    expect(response).to have_http_status(:ok)
    expect(archived.reload).to have_attributes(title: 'Updated archived', team_id: old_team.id)
  end

  it 'reconciles the inherited team when reopening a linked task after a deal transfer', :aggregate_failures do
    account.enable_features!('crm_deals')
    grants = viewer.account_users.find_by!(account: account).access_role.grants
    %w[view update_fields assign].each do |capability|
      grants.find_by!(resource: 'deals', capability: capability).update!(access_scope: 'all')
    end
    grants.find_by!(resource: 'tasks', capability: 'update_fields').update!(access_scope: 'own')
    grants.find_by!(resource: 'tasks', capability: 'transition').update!(access_scope: 'own')
    grants.find_by!(resource: 'tasks', capability: 'assign').update!(access_scope: 'none')
    old_team = create(:team, account: account)
    new_team = create(:team, account: account)
    deal = create(:crm_deal, account: account, owner: viewer, team: old_team)
    task = create(:crm_task, account: account, assignee: viewer, team: old_team, deal: deal,
                             context_kind: 'sales')
    outcome = task.task_type.outcomes.find_by!(code: 'completed')

    post "#{path}/#{task.id}/complete",
         params: { task_outcome_id: outcome.id, lock_version: task.lock_version }, headers: headers, as: :json
    expect(response).to have_http_status(:ok)

    patch "/api/v1/accounts/#{account.id}/crm/deals/#{deal.id}",
          params: { team_id: new_team.id, lock_version: deal.lock_version }, headers: headers, as: :json
    expect(response).to have_http_status(:ok)
    expect(task.reload.team).to eq(old_team)

    post "#{path}/#{task.id}/reopen", params: { lock_version: task.lock_version }, headers: headers, as: :json
    expect(response).to have_http_status(:ok)
    expect(task.reload.team).to eq(new_team)
    expect(task.events.where(event_type: 'task_reopened').last.after_data['team_id']).to eq(new_team.id)

    patch "#{path}/#{task.id}",
          params: { title: 'Edited after reopen', deal_id: deal.id, lock_version: task.lock_version },
          headers: headers, as: :json
    expect(response).to have_http_status(:ok)
    expect(task.reload).to have_attributes(title: 'Edited after reopen', team_id: new_team.id)

    post "#{path}/#{task.id}/save_form",
         params: { title: 'Saved after reopen', deal_id: deal.id, lock_version: task.lock_version,
                   idempotency_key: SecureRandom.uuid }, headers: headers, as: :json
    expect(response).to have_http_status(:ok)
    expect(task.reload).to have_attributes(title: 'Saved after reopen', team_id: new_team.id)
  end

  it 'paginates only tasks in the authoritative own scope' do
    own_tasks = create_list(:crm_task, 2, account: account, assignee: viewer)
    foreign_user = create(:user, account: account, role: :agent)
    foreign_task = create(:crm_task, account: account, assignee: foreign_user, title: 'Foreign scoped task')

    get path, params: { page: 1, per_page: 1 }, headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    returned_ids = response.parsed_body.fetch('payload').pluck('id')
    expect(returned_ids.size).to eq(1)
    expect(returned_ids).to all(be_in(own_tasks.map(&:id)))
    expect(response.parsed_body.fetch('meta')).to include(
      'count' => 2,
      'page' => 1,
      'per_page' => 1,
      'has_more' => true
    )
    expect(response.parsed_body.to_json).not_to include(foreign_task.title)
  end

  it 'returns not found for a task and idempotency key outside the authoritative scope' do
    foreign_user = create(:user, account: account, role: :agent)
    foreign_task = create(
      :crm_task,
      account: account,
      assignee: foreign_user,
      idempotency_key: 'foreign-task-key'
    )

    get "#{path}/#{foreign_task.id}", headers: headers, as: :json
    expect(response).to have_http_status(:not_found)

    post path,
         params: { title: 'Probe', assignee_id: viewer.id, idempotency_key: 'foreign-task-key' },
         headers: headers,
         as: :json
    expect(response).to have_http_status(:not_found)
  end

  it 'caps per_page at the server maximum' do
    create(:crm_task, account: account, assignee: viewer)

    get path, params: { page: 1, per_page: 50_000 }, headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('meta', 'per_page')).to eq(500)
  end

  it 'returns timed tasks that overlap the calendar viewport' do
    spanning_task = create(
      :crm_task,
      account: account,
      assignee: viewer,
      start_at: Time.zone.parse('2026-09-01 09:00:00'),
      due_at: Time.zone.parse('2026-09-30 18:00:00')
    )
    create(
      :crm_task,
      account: account,
      assignee: viewer,
      start_at: Time.zone.parse('2026-10-01 09:00:00'),
      due_at: Time.zone.parse('2026-10-01 10:00:00')
    )

    get path,
        params: {
          calendar_from: '2026-09-07T00:00:00Z',
          calendar_from_date: '2026-09-07',
          calendar_to: '2026-09-14T00:00:00Z',
          calendar_to_date: '2026-09-14',
          task_state: 'active'
        },
        headers: headers,
        as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch('payload').pluck('id')).to eq([spanning_task.id])
  end

  it 'filters and independently paginates workspace task time buckets' do
    travel_to(Time.zone.parse('2026-09-19 10:00:00')) do
      as_of = Time.current.iso8601(6)
      normalized_as_of = Time.current.in_time_zone(account.workspace_working_hours_timezone).iso8601(6)
      records = {
        'overdue' => create(:crm_task, account: account, assignee: viewer, due_at: 1.hour.ago),
        'today' => create(:crm_task, account: account, assignee: viewer, due_at: 1.hour.from_now),
        'tomorrow' => create(:crm_task, account: account, assignee: viewer, all_day: true, due_on: Date.current + 1.day),
        'nextWeek' => create(:crm_task, account: account, assignee: viewer, all_day: true, due_on: Date.current + 3.days),
        'thisMonth' => create(:crm_task, account: account, assignee: viewer, all_day: true, due_on: Date.current + 10.days),
        'future' => create(:crm_task, account: account, assignee: viewer, all_day: true, due_on: Date.current + 2.months),
        'unscheduled' => create(:crm_task, account: account, assignee: viewer, due_at: nil, due_on: nil)
      }
      second_today = create(:crm_task, account: account, assignee: viewer, all_day: true, due_on: Date.current)

      records.each do |bucket, task|
        get path,
            params: { as_of: as_of, page: 1, per_page: 1, task_state: 'active', time_bucket: bucket },
            headers: headers,
            as: :json

        expect(response).to have_http_status(:ok)
        returned_ids = response.parsed_body.fetch('payload').pluck('id')
        if bucket == 'today'
          expect(returned_ids).to all(be_in([task.id, second_today.id]))
        else
          expect(returned_ids).to eq([task.id])
        end
        expected_count = bucket == 'today' ? 2 : 1
        expect(response.parsed_body.fetch('meta')).to include(
          'count' => expected_count,
          'has_more' => (bucket == 'today'),
          'page' => 1,
          'per_page' => 1,
          'as_of' => normalized_as_of
        )
      end

      expect(second_today).to be_persisted
    end
  end

  it 'uses the same server snapshot across bucket requests processed at different times' do
    snapshot = Time.zone.parse('2026-09-19 10:00:00')
    boundary_task = create(:crm_task, account: account, assignee: viewer, due_at: snapshot + 30.seconds)

    travel_to(snapshot + 1.minute) do
      get path,
          params: { as_of: snapshot.iso8601(6), task_state: 'active', time_bucket: 'overdue' },
          headers: headers,
          as: :json
      expect(response.parsed_body.fetch('payload').pluck('id')).not_to include(boundary_task.id)

      get path,
          params: { as_of: snapshot.iso8601(6), task_state: 'active', time_bucket: 'today' },
          headers: headers,
          as: :json
      expect(response.parsed_body.fetch('payload').pluck('id')).to include(boundary_task.id)
    end
  end

  it 'returns the bucket snapshot in the workspace timezone' do
    travel_to(Time.utc(2026, 9, 19, 20, 0, 0)) do
      get path,
          params: { task_state: 'active', time_bucket: 'today' },
          headers: headers,
          as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig('meta', 'as_of')).to eq('2026-09-20T01:00:00.000000+05:00')
    end
  end

  it 'filters and stably sorts a bounded list page on the server' do
    deadline = 1.day.from_now
    active_first = create(:crm_task, account: account, assignee: viewer, title: 'Same', due_at: deadline)
    active_second = create(:crm_task, account: account, assignee: viewer, title: 'Same', due_at: deadline)
    completed = create(:crm_task, account: account, assignee: viewer, title: 'Same', completed_at: Time.current)

    get path,
        params: {
          page: 1,
          per_page: 1,
          q: 'Same',
          sort_by: 'dueAt',
          sort_direction: 'asc',
          task_state: 'active'
        },
        headers: headers,
        as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch('payload').pluck('id')).to eq([active_first.id])
    expect(response.parsed_body.fetch('meta')).to include(
      'count' => 2,
      'page' => 1,
      'per_page' => 1,
      'has_more' => true
    )
    expect(response.parsed_body.fetch('payload').pluck('id')).not_to include(completed.id)

    get path,
        params: {
          page: 2,
          per_page: 1,
          q: 'Same',
          sort_by: 'dueAt',
          sort_direction: 'asc',
          task_state: 'active'
        },
        headers: headers,
        as: :json

    expect(response.parsed_body.fetch('payload').pluck('id')).to eq([active_second.id])
  end

  it 'searches task catalog display names on the server' do
    task_type = create(:crm_task_type, account: account, name: 'Контрольный звонок', code: 'follow_up_call')
    current_task = create(:crm_task, account: account, assignee: viewer, task_type: task_type)
    legacy_task = create(
      :crm_task, account: account, assignee: viewer, task_type: nil, activity_type: task_type.code
    )
    create(:crm_task, account: account, assignee: viewer)

    get path, params: { q: 'Контрольный звонок' }, headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch('payload').pluck('id')).to contain_exactly(current_task.id, legacy_task.id)
    expect(response.parsed_body.dig('meta', 'count')).to eq(2)
  end

  it 'sorts activity types by their displayed catalog names' do
    alphabetically_last = create(:crm_task_type, account: account, name: 'Явка', code: 'a_call')
    alphabetically_first = create(:crm_task_type, account: account, name: 'Актуализация', code: 'z_follow_up')
    last_task = create(
      :crm_task, account: account, assignee: viewer, task_type: nil, activity_type: alphabetically_last.code
    )
    first_task = create(
      :crm_task, account: account, assignee: viewer, task_type: nil, activity_type: alphabetically_first.code
    )

    get path, params: { sort_by: 'activityType', sort_direction: 'asc' }, headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch('payload').pluck('id')).to eq([first_task.id, last_task.id])
  end

  it 'searches displayed custom field labels and formatted values on the server' do
    [
      { key: 'customer_segment', label: 'Сегмент клиента', field_type: 'select',
        options: [{ label: 'Крупный клиент', value: 'enterprise' }] },
      { key: 'budget', label: 'Бюджет', field_type: 'currency' },
      { key: 'follow_up_on', label: 'Дата контакта', field_type: 'date' },
      { key: 'follow_up_at', label: 'Время контакта', field_type: 'datetime' },
      { key: 'verified', label: 'Проверено', field_type: 'checkbox' },
      { key: 'other_text', label: 'Другой текст', field_type: 'text' },
      { key: 'literal_true', label: 'Строковое true', field_type: 'text' }
    ].each do |attributes|
      create(:crm_field_definition, account: account, entity_kind: 'task', **attributes)
    end
    matching_task = create(
      :crm_task,
      account: account,
      assignee: viewer,
      custom_attributes: {
        'customer_segment' => 'enterprise',
        'budget' => 1000,
        'follow_up_at' => '2026-09-18T20:30:00-05:00',
        'follow_up_on' => '2026-09-18',
        'verified' => true
      }
    )
    create(
      :crm_task,
      account: account,
      assignee: viewer,
      custom_attributes: { 'literal_true' => 'true', 'other_text' => 'enterprise' }
    )

    ['Сегмент клиента', 'Крупный клиент', '1 000'].each do |query|
      get path, params: { q: query }, headers: headers, as: :json
      expect(response.parsed_body.fetch('payload').pluck('id')).to eq([matching_task.id])
    end

    get path, params: { q: '18 сент. 2026 г.', q_date_alias: '2026-09-18' }, headers: headers, as: :json
    expect(response.parsed_body.fetch('payload').pluck('id')).to eq([matching_task.id])

    get path,
        params: { q: 'Sep 19, 2026, 01:30', q_datetime_alias: '2026-09-19T01:30Z' },
        headers: headers,
        as: :json
    expect(response.parsed_body.fetch('payload').pluck('id')).to eq([matching_task.id])

    get path, params: { q: '1,000', q_numeric_alias: '1000' }, headers: headers, as: :json
    expect(response.parsed_body.fetch('payload').pluck('id')).to eq([matching_task.id])

    get path, params: { q: 'Подтверждено', q_checked: true }, headers: headers, as: :json
    expect(response.parsed_body.fetch('payload').pluck('id')).to eq([matching_task.id])
  end

  it 'ignores semantically invalid datetime aliases without raising' do
    get path,
        params: { q: 'impossible date', q_datetime_alias: '2026-02-31T25:99Z' },
        headers: headers,
        as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch('payload')).to be_empty
  end

  it 'does not apply percent display aliases to number or currency fields' do
    create(:crm_field_definition, account: account, entity_kind: 'task', key: 'discount', field_type: 'percent')
    create(:crm_field_definition, account: account, entity_kind: 'task', key: 'budget', field_type: 'currency')
    matching_task = create(:crm_task, account: account, assignee: viewer, custom_attributes: { 'discount' => 15 })
    create(:crm_task, account: account, assignee: viewer, custom_attributes: { 'budget' => 15 })

    get path, params: { q: '15%' }, headers: headers, as: :json
    expect(response.parsed_body.fetch('payload').pluck('id')).to eq([matching_task.id])
  end

  it 'does not search labels for custom values hidden by the formatter' do
    [
      { key: 'empty_text', label: 'Пустой текст', field_type: 'text' },
      { key: 'empty_multi', label: 'Пустой список', field_type: 'multiselect', options: ['Один'] },
      { key: 'unchecked', label: 'Не отмечено', field_type: 'checkbox' }
    ].each do |attributes|
      create(:crm_field_definition, account: account, entity_kind: 'task', **attributes)
    end
    create(
      :crm_task,
      account: account,
      assignee: viewer,
      custom_attributes: { 'empty_multi' => [], 'empty_text' => '', 'unchecked' => false }
    )

    ['Пустой текст', 'Пустой список', 'Не отмечено'].each do |query|
      get path, params: { q: query }, headers: headers, as: :json
      expect(response.parsed_body.fetch('payload')).to be_empty
    end
  end

  it 'pages a synthetic task set without duplicates or gaps' do
    expected_ids = create_list(:crm_task, 51, account: account, assignee: viewer, title: 'Scale task').pluck(:id).sort
    actual_ids = (1..3).flat_map do |page|
      get path,
          params: { page: page, per_page: 25, q: 'Scale task', sort_by: 'id', sort_direction: 'asc' },
          headers: headers,
          as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig('meta', 'count')).to eq(51)
      response.parsed_body.fetch('payload').pluck('id')
    end

    expect(actual_ids.each_slice(25).map(&:size)).to eq([25, 25, 1])
    expect(actual_ids).to eq(expected_ids)
    expect(actual_ids.uniq).to eq(actual_ids)
  end
end
