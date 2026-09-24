require 'rails_helper'

RSpec.describe 'Telephony Logical Call Reports API', type: :request do
  let(:account) { create(:account, settings: { 'workspace_timezone' => 'Asia/Almaty' }) }
  let(:viewer) { create(:user, :administrator, account: account) }
  let(:headers) { { api_access_token: viewer.access_token.token } }
  let(:aggregate_path) { "/api/v1/accounts/#{account.id}/telephony/reports/logical_calls" }
  let(:details_path) { "/api/v1/accounts/#{account.id}/telephony/reports/logical_call_details" }
  let(:window) do
    {
      from_local: '2026-01-01T00:00:00',
      to_local: '2026-02-01T00:00:00',
      as_of: '2026-02-02T00:00:00Z',
      metric: 'connected',
      dimension: 'provider'
    }
  end
  let(:voice_inbox) { create(:channel_voice, :sipuni, account: account).inbox }

  before { account.enable_features!('channel_voice') }

  def enable_enforced_access!
    AccessControl::LegacyRoleAssigner.call(account: account, apply: true)
    AccessControl::ModeTransition.call(account: account, to: :shadow)
    AccessControl::ModeTransition.call(account: account, to: :enforced)
  end

  def set_scope(account_user, capability, scope)
    grants = account_user.access_role.grants
    grant = grants.find_or_initialize_by(account: account, resource: 'telephony_calls', capability: capability)
    grant.update!(access_scope: scope)
  end

  def insert_connected_fact( # rubocop:disable Metrics/MethodLength
    identity: 'request-call', account_record: account, inbox: voice_inbox, actor: nil, actor_team: nil
  )
    conversation = create(:conversation, account: account_record, inbox: inbox)
    source = create(
      :telephony_call_session,
      account: account_record,
      conversation: conversation,
      contact: conversation.contact,
      inbox: inbox,
      number_binding: nil,
      external_call_ref: identity,
      provider: 'sipuni',
      direction: 'inbound',
      started_at: nil,
      metadata: {}
    )
    occurred_at = Time.utc(2026, 1, 10, 10)
    Telephony::LogicalCallOccurrence.insert_all!( # rubocop:disable Rails/SkipsModelValidations
      [{
        account_id: account_record.id,
        logical_call_identity: identity,
        logical_call_ref: identity,
        occurrence_kind: 'connected',
        source_kind: 'telephony_call_session',
        source_id: source.id,
        source_ref: source.external_call_ref,
        provider: source.provider,
        direction: source.direction,
        inbox_id_snapshot: inbox.id,
        actor_kind: actor ? 'human' : 'unknown',
        actor_id_snapshot: actor&.id,
        actor_name_snapshot: actor&.name,
        actor_team_id_snapshot: actor_team&.id,
        actor_team_name_snapshot: actor_team&.name,
        occurred_at: occurred_at,
        connected_at: occurred_at,
        reliability: 'exact',
        reliable_since: occurred_at,
        source_version: 1,
        definition_version: 1,
        revision: 1,
        created_at: occurred_at
      }]
    )
  end

  it 'recognizes both production GET routes without test-only routing' do
    [[aggregate_path, 'logical_calls'], [details_path, 'logical_call_details']].each do |path, action|
      expect(Rails.application.routes.recognize_path(path, method: :get)).to include(
        controller: 'api/v1/accounts/telephony/reports', action: action, account_id: account.id.to_s
      )
      expect { Rails.application.routes.recognize_path(path, method: :post) }
        .to raise_error(ActionController::RoutingError)
    end
  end

  it 'returns aggregate/detail parity with a shared fixed-as-of fingerprint' do
    insert_connected_fact

    get aggregate_path, params: window, headers: headers, as: :json
    aggregate = response.parsed_body
    expect(response).to have_http_status(:ok)

    get details_path, params: window.merge(page: 1, per_page: 1), headers: headers, as: :json
    details = response.parsed_body

    expect(response).to have_http_status(:ok)
    expect(aggregate.dig('payload', 'rows').sum { |row| row['total_count'] }).to eq(1)
    expect(details.dig('meta', 'total_count')).to eq(1)
    expect(details.dig('payload', 'rows', 0, 'logical_call_identity')).to eq('request-call')
    expect(aggregate.dig('meta', 'query_fingerprint')).to eq(details.dig('meta', 'query_fingerprint'))
    expect(details.dig('meta', 'as_of')).to eq('2026-02-02T00:00:00.000000Z')
  end

  it 'requires the Voice feature' do
    account.disable_features!('channel_voice')
    get aggregate_path, params: window, headers: headers, as: :json
    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body['code']).to eq('FEATURE_DISABLED')
  end

  it 'returns not_configured for an authorized account without a Voice route' do
    get aggregate_path, params: window, headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('meta', 'state')).to eq('not_configured')
    expect(response.parsed_body.dig('meta', 'exact_zero_supported')).to be(false)
  end

  it 'returns a stable not_authorized state when report capability is denied' do
    denied_user = create(:user, account: account, role: :agent)

    get aggregate_path, params: window, headers: { 'api_access_token' => denied_user.access_token.token }, as: :json

    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body).to include('code' => 'NOT_AUTHORIZED', 'state' => 'not_authorized')
  end

  it 'allows administrator reporting in enforced mode with bootstrapped grants' do
    voice_inbox
    viewer
    enable_enforced_access!
    grants = viewer.account_users.find_by!(account: account).access_role.grants
    expect(grants.where(resource: 'telephony_calls').pluck(:capability, :access_scope))
      .to contain_exactly(%w[view all], %w[view_reports all])

    get aggregate_path, params: window, headers: headers, as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('meta', 'coverage_state')).to eq('unknown')
  end

  it 'keeps explicit administrator denial after bootstrap and in enforced mode' do
    voice_inbox
    viewer
    enable_enforced_access!
    administrator = viewer.account_users.find_by!(account: account).access_role
    administrator.grants.find_by!(resource: 'telephony_calls', capability: 'view_reports').update!(access_scope: 'none')

    AccessControl::LegacyRoleAssigner.call(account: account, apply: true)
    get aggregate_path, params: window, headers: headers, as: :json

    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body).to include('code' => 'NOT_AUTHORIZED', 'state' => 'not_authorized')
  end

  it 'preserves legacy report_manage authorization in shadow without inventing a grant' do
    report_viewer = create(:user, account: account, role: :agent)
    role = create(:custom_role, account: account, permissions: ['report_manage'])
    report_viewer.account_users.find_by!(account: account).update!(custom_role: role)
    voice_inbox
    AccessControl::ModeTransition.call(account: account, to: :shadow)

    get aggregate_path, params: window, headers: { api_access_token: report_viewer.access_token.token }, as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('meta', 'state')).to eq('ready')
  end

  it 'denies missing and explicitly denied grants in enforced mode rather than reporting zero' do
    reporter = create(:user, account: account, role: :agent)
    voice_inbox
    enable_enforced_access!
    reporter_account_user = reporter.account_users.find_by!(account: account)
    reporter_headers = { api_access_token: reporter.access_token.token }
    get aggregate_path, params: window, headers: reporter_headers, as: :json
    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body).to include('code' => 'NOT_AUTHORIZED', 'state' => 'not_authorized')

    set_scope(reporter_account_user, 'view', 'all')
    set_scope(reporter_account_user, 'view_reports', 'none')
    get details_path, params: window, headers: reporter_headers, as: :json
    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body).to include('code' => 'NOT_AUTHORIZED', 'state' => 'not_authorized')
  end

  it 'intersects own/team/all with Voice membership, tenant and hidden filters' do # rubocop:disable RSpec/MultipleExpectations
    reporter = create(:user, account: account, role: :agent)
    teammate = create(:user, account: account)
    outsider = create(:user, account: account)
    team = create(:team, account: account)
    hidden_inbox = create(:channel_voice, :sipuni, account: account).inbox
    create(:inbox_member, inbox: voice_inbox, user: reporter)
    create(:team_member, team: team, user: reporter)
    insert_connected_fact(identity: 'own', actor: reporter)
    insert_connected_fact(identity: 'team', actor: teammate, actor_team: team)
    insert_connected_fact(identity: 'outsider', actor: outsider)
    insert_connected_fact(identity: 'unknown')
    insert_connected_fact(identity: 'hidden', actor: reporter, inbox: hidden_inbox)
    foreign_account = create(:account)
    foreign_inbox = create(:channel_voice, :sipuni, account: foreign_account).inbox
    foreign_actor = create(:user, account: foreign_account)
    insert_connected_fact(identity: 'foreign', account_record: foreign_account, inbox: foreign_inbox, actor: foreign_actor)
    enable_enforced_access!
    account_user = reporter.account_users.find_by!(account: account)
    reporter_headers = { api_access_token: reporter.access_token.token }

    set_scope(account_user, 'view', 'own')
    set_scope(account_user, 'view_reports', 'all')
    get details_path, params: window, headers: reporter_headers, as: :json
    expect(response.parsed_body.dig('payload', 'rows').pluck('logical_call_identity')).to eq(['own'])

    set_scope(account_user, 'view', 'all')
    set_scope(account_user, 'view_reports', 'team')
    get details_path, params: window, headers: reporter_headers, as: :json
    expect(response.parsed_body.dig('payload', 'rows').pluck('logical_call_identity')).to contain_exactly('own', 'team')

    set_scope(account_user, 'view_reports', 'all')
    get aggregate_path, params: window, headers: reporter_headers, as: :json
    aggregate = response.parsed_body
    get details_path, params: window.merge(page: 1, per_page: 100), headers: reporter_headers, as: :json
    details = response.parsed_body
    expect(details.dig('payload', 'rows').pluck('logical_call_identity')).to contain_exactly('own', 'team', 'outsider', 'unknown')
    expect(details.dig('meta', 'observed_count')).to eq(4)
    expect(aggregate.dig('meta', 'observed_count')).to eq(details.dig('meta', 'observed_count'))
    expect(aggregate.dig('meta', 'query_fingerprint')).to eq(details.dig('meta', 'query_fingerprint'))

    [hidden_inbox.id, foreign_inbox.id].each do |inbox_id|
      get details_path, params: window.merge(inbox_id: inbox_id), headers: reporter_headers, as: :json
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body).to include('code' => 'INVALID_REPORT_QUERY', 'error' => 'inbox_id is invalid')
    end
    get details_path, params: window.merge(actor_id: foreign_actor.id), headers: reporter_headers, as: :json
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body).to include('code' => 'INVALID_REPORT_QUERY', 'error' => 'actor_id is invalid')

    set_scope(account_user, 'view', 'none')
    get aggregate_path, params: window, headers: reporter_headers, as: :json
    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body).to include('state' => 'not_authorized')
  end

  it 'returns the report validation contract for malformed windows and missing detail metric' do
    get aggregate_path, params: window.merge(from_local: '2026-01-01T00:00:00Z'), headers: headers, as: :json
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body['code']).to eq('INVALID_REPORT_QUERY')

    get details_path, params: window.except(:metric), headers: headers, as: :json
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body).to include('code' => 'INVALID_REPORT_QUERY', 'error' => 'metric is required for details')
  end
end
