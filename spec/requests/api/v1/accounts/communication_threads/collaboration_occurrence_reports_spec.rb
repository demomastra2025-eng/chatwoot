require 'rails_helper'

RSpec.describe 'CommunicationThread Collaboration Occurrence Reports API', type: :request do
  let(:account) { create(:account, settings: { 'workspace_timezone' => 'Asia/Almaty' }) }
  let(:viewer) { create(:user, :administrator, account: account) }
  let(:headers) { viewer.create_new_auth_token }
  let(:aggregate_path) { "/api/v1/accounts/#{account.id}/communication_threads/reports/collaboration_occurrences" }
  let(:details_path) { "/api/v1/accounts/#{account.id}/communication_threads/reports/collaboration_occurrence_details" }
  let(:window) do
    { fact_kind: 'participant_lifecycle', from_date: '2026-09-21', to_date: '2026-09-22', as_of_date: '2026-09-22' }
  end

  before { account.enable_features!('communication_threads') }

  def enable_enforced_access!
    AccessControl::LegacyRoleAssigner.call(account: account, apply: true)
    AccessControl::ModeTransition.call(account: account, to: :shadow)
    AccessControl::ModeTransition.call(account: account, to: :enforced)
  end

  def set_scope(capability, scope)
    grants = viewer.account_users.find_by!(account: account).access_role.grants
    grant = grants.find_or_initialize_by(account: account, resource: 'conversations', capability: capability)
    grant.update!(access_scope: scope)
  end

  def create_fact(thread, participant: viewer, occurred_at: Time.utc(2026, 9, 21, 6))
    create(
      :communication_thread_participant_lifecycle_fact,
      account: thread.account,
      communication_thread: thread,
      participant_id: participant.id,
      occurred_at: occurred_at,
      created_at: occurred_at,
      reliable_since: occurred_at
    )
  end

  it 'returns source-specific metadata and matching aggregate/details' do
    thread = create(:communication_thread, account: account)
    fact = create_fact(thread)

    get aggregate_path, params: window, headers: headers, as: :json
    aggregate = response.parsed_body
    get details_path, params: window, headers: headers, as: :json
    details = response.parsed_body

    expect(response).to have_http_status(:ok)
    expect(aggregate.dig('payload', 'rows').sole).to include(
      'fact_kind' => 'participant_lifecycle',
      'source' => 'communication_thread_participant_lifecycle_facts',
      'occurrence_count' => 1,
      'distinct_thread_count' => 1
    )
    expect(details.dig('payload', 'rows').sole).to include(
      'occurrence_id' => fact.id,
      'communication_thread_id' => thread.id,
      'reliability' => 'exact_immutable_occurrence'
    )
    expect(details['meta']).to include(
      'total_count' => 1,
      'owner_definition' => 'canonical_thread_owner_is_not_collaboration_actor_and_receives_no_credit_from_this_report',
      'missing_source_definition' => 'manual_call_is_unknown_not_zero_until_a_durable_actor_occurrence_fact_exists'
    )
    expect(details.dig('meta', 'source_catalog')).to include(
      include('fact_kind' => 'manual_call', 'availability' => 'unknown_missing_durable_fact')
    )
  end

  it 'applies canonical owner-only view intersect view_reports for own, team, all, and none' do
    teammate = create(:user, account: account)
    outsider = create(:user, account: account)
    team = create(:team, account: account)
    create(:team_member, team: team, user: viewer)
    own_thread = create(:communication_thread, account: account, assignee: viewer)
    team_thread = create(:communication_thread, account: account, assignee: teammate, team: team)
    hidden_thread = create(:communication_thread, account: account, assignee: outsider)
    participant_only = create(:communication_thread, account: account, assignee: outsider)
    create(:communication_thread_participant, account: account, communication_thread: participant_only, user: viewer)
    [own_thread, team_thread, hidden_thread, participant_only].each_with_index do |thread, index|
      create_fact(thread, occurred_at: Time.utc(2026, 9, 21, 6, index))
    end
    enable_enforced_access!

    set_scope('view', 'own')
    set_scope('view_reports', 'all')
    get details_path, params: window, headers: headers, as: :json
    expect(response.parsed_body.dig('payload', 'rows').pluck('communication_thread_id')).to contain_exactly(own_thread.id)

    set_scope('view', 'all')
    set_scope('view_reports', 'team')
    get details_path, params: window, headers: headers, as: :json
    expect(response.parsed_body.dig('payload', 'rows').pluck('communication_thread_id')).to contain_exactly(own_thread.id, team_thread.id)

    set_scope('view_reports', 'all')
    get details_path, params: window, headers: headers, as: :json
    expect(response.parsed_body.dig('payload', 'rows').pluck('communication_thread_id'))
      .to contain_exactly(own_thread.id, team_thread.id, hidden_thread.id, participant_only.id)

    set_scope('view', 'none')
    get aggregate_path, params: window, headers: headers, as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('payload', 'rows')).to be_empty
    expect(response.parsed_body.dig('meta', 'total_count')).to eq(0)

    set_scope('view', 'all')
    set_scope('view_reports', 'none')
    get aggregate_path, params: window, headers: headers, as: :json
    expect(response).to have_http_status(:unauthorized)
  end

  it 'does not turn participant-only visibility into owner report visibility or an oracle' do
    hidden_owner = create(:user, account: account)
    hidden_thread = create(:communication_thread, account: account, assignee: hidden_owner)
    create(:communication_thread_participant, account: account, communication_thread: hidden_thread, user: viewer)
    create_fact(hidden_thread)
    enable_enforced_access!
    set_scope('view', 'own')
    set_scope('view_reports', 'all')

    get details_path, params: window, headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('payload', 'rows')).to be_empty
    expect(response.parsed_body.dig('meta', 'total_count')).to eq(0)
  end

  it 'enforces authentication, report authorization, feature gate, and tenant isolation' do
    foreign_account = create(:account)
    foreign_participant = create(:user, account: foreign_account)
    foreign_thread = create(:communication_thread, account: foreign_account)
    create_fact(foreign_thread, participant: foreign_participant)

    get aggregate_path, params: window, as: :json
    expect(response).to have_http_status(:unauthorized)

    plain_agent = create(:user, account: account)
    get aggregate_path, params: window, headers: plain_agent.create_new_auth_token, as: :json
    expect(response).to have_http_status(:unauthorized)

    account.disable_features!('communication_threads')
    get aggregate_path, params: window, headers: headers, as: :json
    expect(response).to have_http_status(:forbidden)
    account.enable_features!('communication_threads')

    get aggregate_path, params: window, headers: headers, as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('meta', 'total_count')).to eq(0)
  end

  it 'rejects unavailable and unsupported source contracts instead of fabricating zero' do
    get aggregate_path, params: window.merge(fact_kind: 'manual_call'), headers: headers, as: :json
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body).to include(
      'code' => 'INVALID_REPORT_QUERY',
      'error' => 'manual_call occurrence source is unavailable: durable actor fact is missing'
    )

    get aggregate_path,
        params: window.merge(fact_kind: 'private_message'),
        headers: headers,
        as: :json
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body['error']).to eq('as_of_date is not supported for private_message retained rows')
  end
end
