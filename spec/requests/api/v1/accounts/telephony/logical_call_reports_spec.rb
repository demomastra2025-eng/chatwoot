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

  around do |example|
    with_routing do |routes|
      routes.draw do
        get '/api/v1/accounts/:account_id/telephony/reports/logical_calls',
            to: 'api/v1/accounts/telephony/reports#logical_calls'
        get '/api/v1/accounts/:account_id/telephony/reports/logical_call_details',
            to: 'api/v1/accounts/telephony/reports#logical_call_details'
      end
      example.run
    end
  end

  before { account.enable_features!('channel_voice') }

  def insert_connected_fact(identity: 'request-call') # rubocop:disable Metrics/MethodLength
    conversation = create(:conversation, account: account, inbox: voice_inbox)
    source = create(
      :telephony_call_session,
      account: account,
      conversation: conversation,
      contact: conversation.contact,
      inbox: voice_inbox,
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
        account_id: account.id,
        logical_call_identity: identity,
        logical_call_ref: identity,
        occurrence_kind: 'connected',
        source_kind: 'telephony_call_session',
        source_id: source.id,
        source_ref: source.external_call_ref,
        provider: source.provider,
        direction: source.direction,
        inbox_id_snapshot: voice_inbox.id,
        actor_kind: 'unknown',
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

  it 'returns forbidden rather than a validation error without a telephony grant contract in shadow or enforced mode' do
    voice_inbox
    %w[shadow enforced].each do |mode|
      account.authorize_access_control_mode_transition { account.update!(access_control_mode: mode) }
      get aggregate_path, params: window, headers: headers, as: :json

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body).to include('code' => 'NOT_AUTHORIZED', 'state' => 'not_authorized')
    end
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
