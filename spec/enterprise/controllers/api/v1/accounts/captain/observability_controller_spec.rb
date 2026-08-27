# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Api::V1::Accounts::Captain::Observability', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }

  def json_response
    response.parsed_body.deep_symbolize_keys
  end

  describe 'GET /api/v1/accounts/{account.id}/captain/observability' do
    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        get "/api/v1/accounts/#{account.id}/captain/observability",
            as: :json

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an agent' do
      it 'returns unauthorized' do
        get "/api/v1/accounts/#{account.id}/captain/observability",
            headers: agent.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an admin' do
      let!(:assistant_event) do
        create(
          :llm_event,
          account: account,
          feature: 'assistant',
          model: 'gpt-4.1-mini',
          event_name: 'llm.chat.complete',
          runtime_mode: 'captain_runtime',
          status: 'completed',
          assistant_id: 101,
          request_id: 'request-1',
          session_id: 'session-1',
          trace_id: 'trace-1',
          conversation_id: 1001,
          conversation_display_id: 501,
          project_case_id: 'support_reply',
          total_tokens: 180,
          estimated_cost: 0.0018,
          payload: { trace_id: 'trace-1', stage: 'output', flagged_categories: ['violence'] },
          created_at: 2.hours.ago
        )
      end
      let!(:tool_event) do
        create(
          :llm_event,
          account: account,
          feature: 'assistant',
          model: 'gpt-4.1-mini',
          event_name: 'llm.tool.complete',
          runtime_mode: 'captain_runtime',
          status: 'completed',
          assistant_id: 101,
          request_id: 'request-2',
          session_id: 'session-1',
          trace_id: 'trace-2',
          project_case_id: 'support_reply',
          tool_name: 'search_documentation',
          tool_failure: true,
          error: true,
          payload: { trace_id: 'trace-2' },
          created_at: 1.hour.ago
        )
      end
      let!(:other_account_event) { create(:llm_event) }

      before do
        allow(Llm::Monitoring::AlertNotifier).to receive(:state_for).and_return(
          status: 'delivered',
          last_delivery_at: 10.minutes.ago.iso8601,
          last_delivery_channels: ['email']
        )
      end

      it 'returns an account-scoped observability snapshot and recent events' do
        account.update!(
          captain_observability: {
            'default_lookback_days' => 7,
            'retention_days' => 120
          }
        )

        get "/api/v1/accounts/#{account.id}/captain/observability",
            headers: admin.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        expect(json_response[:snapshot]).to include(
          total_events: 2,
          request_count: 1,
          error_count: 1,
          tool_failure_count: 1
        )
        expect(json_response[:time_series]).to include(
          bucket: 'day'
        )
        expect(json_response[:time_series][:points]).not_to be_empty
        expect(json_response[:release_gate]).to include(
          status: 'insufficient_data'
        )
        expect(json_response[:alerts]).to include(
          status: 'insufficient_data',
          release_gate_status: 'insufficient_data',
          active_count: 0
        )
        expect(json_response[:runtime_health]).to include(
          status: 'insufficient_data',
          account_id: account.id
        )
        expect(json_response[:runtime_health][:checks]).to include(
          include(name: 'event_ingestion', status: 'pass')
        )
        expect(json_response[:performance_budget]).to include(
          status: 'pass',
          total_project_cases: 1,
          uncovered_event_count: 0
        )
        expect(json_response[:performance_budget][:cases]).to include(
          include(
            project_case_id: 'support_reply',
            event_count: 2,
            request_count: 1,
            status: 'pass'
          )
        )
        expect(json_response[:alert_delivery_state]).to include(
          status: 'delivered',
          last_delivery_channels: ['email']
        )
        expect(json_response[:preferences]).to include(
          default_lookback_days: 7,
          retention_days: 120
        )
        expect(json_response[:meta]).to include(
          count: 2,
          current_page: 1,
          per_page: 25
        )
        expect(json_response[:payload].size).to eq(2)
        expect(json_response[:payload].map { |event| event[:id] }).to contain_exactly(assistant_event.id, tool_event.id)
        expect(json_response[:payload].find { |event| event[:id] == assistant_event.id }).to include(
          feature: 'assistant',
          request_id: 'request-1',
          conversation_display_id: 501,
          trace_id: 'trace-1',
          moderation_stage: 'output',
          flagged_categories: ['violence'],
          details: {
            trace_id: 'trace-1',
            stage: 'output',
            flagged_categories: ['violence']
          }
        )
        expect(json_response[:payload].map { |event| event[:id] }).not_to include(other_account_event.id)
      end

      it 'enforces assistant logs while supporting event, assistant, and date filters' do
        create(
          :llm_event,
          account: account,
          feature: 'copilot',
          event_name: 'llm.chat.complete',
          error: true,
          error_code: 'provider_unavailable',
          created_at: 2.hours.ago
        )

        get "/api/v1/accounts/#{account.id}/captain/observability",
            params: {
              feature: 'copilot',
              event_name: 'llm.chat.complete',
              assistant_id: 101,
              since: 3.hours.ago.to_i.to_s,
              until: 90.minutes.ago.to_i.to_s
            },
            headers: admin.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        expect(json_response[:meta][:count]).to eq(1)
        expect(json_response[:meta][:applied_filters]).to include(
          feature: 'assistant',
          event_name: 'llm.chat.complete',
          assistant_id: 101
        )
        expect(json_response[:payload].map { |event| event[:id] }).to eq([assistant_event.id])
        expect(json_response[:snapshot]).to include(
          total_events: 1,
          request_count: 1
        )
        expect(json_response[:time_series][:bucket]).to eq('hour')
        expect(json_response[:time_series][:points].sum { |point| point[:request_count] }).to eq(1)
        expect(json_response[:release_gate][:current_period][:metrics]).to include(
          request_count: 1
        )
        expect(json_response[:runtime_health]).to include(
          status: 'insufficient_data',
          recent_error_codes: {}
        )
      end

      it 'supports filtering by semantic event flags' do
        get "/api/v1/accounts/#{account.id}/captain/observability",
            params: { flag: 'tool_failure' },
            headers: admin.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        expect(json_response[:meta][:count]).to eq(1)
        expect(json_response[:meta][:applied_filters]).to include(flag: 'tool_failure')
        expect(json_response[:payload].map { |event| event[:id] }).to eq([tool_event.id])
      end

      it 'supports filtering by session identifier' do
        get "/api/v1/accounts/#{account.id}/captain/observability",
            params: { session_id: 'session-1' },
            headers: admin.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        expect(json_response[:meta][:count]).to eq(2)
        expect(json_response[:meta][:applied_filters]).to include(session_id: 'session-1')
        expect(json_response[:payload].map { |event| event[:id] }).to contain_exactly(
          assistant_event.id,
          tool_event.id
        )
      end

      it 'supports filtering by trace identifier' do
        get "/api/v1/accounts/#{account.id}/captain/observability",
            params: { trace_id: 'trace-1' },
            headers: admin.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        expect(json_response[:meta][:count]).to eq(1)
        expect(json_response[:meta][:applied_filters]).to include(trace_id: 'trace-1')
        expect(json_response[:payload].map { |event| event[:id] }).to eq([assistant_event.id])
      end

      it 'caps per_page to avoid oversized responses' do
        get "/api/v1/accounts/#{account.id}/captain/observability",
            params: { per_page: 999 },
            headers: admin.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        expect(json_response[:meta][:per_page]).to eq(100)
      end
    end
  end

  describe 'GET /api/v1/accounts/{account.id}/captain/observability/metrics' do
    let!(:event) do
      create(
        :llm_event,
        account: account,
        feature: 'assistant',
        model: 'gpt-4.1-mini',
        event_name: 'llm.chat.complete',
        total_tokens: 160,
        estimated_cost: 0.00012
      )
    end

    it 'returns Prometheus-compatible account-scoped AI metrics for admins' do
      create(:llm_event, account: account, feature: 'copilot', event_name: 'llm.chat.complete')

      get "/api/v1/accounts/#{account.id}/captain/observability/metrics",
          params: { feature: 'copilot' },
          headers: admin.create_new_auth_token

      expect(response).to have_http_status(:success)
      expect(response.media_type).to start_with('text/plain')
      expect(response.content_type).to include('version=0.0.4')
      expect(response.body).to include("llm_events_total{account_id=\"#{account.id}\"} 1")
      expect(response.body).to include("llm_requests_by_model_total{account_id=\"#{account.id}\",model=\"gpt-4.1-mini\"} 1")
      expect(response.body).to include("llm_release_gate_status{account_id=\"#{account.id}\",status=\"insufficient_data\"} 1")
      expect(response.body).to include("llm_alerts_active_total{account_id=\"#{account.id}\"} 0")
    end

    it 'rejects non-admin users' do
      get "/api/v1/accounts/#{account.id}/captain/observability/metrics",
          headers: agent.create_new_auth_token

      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe 'GET /api/v1/accounts/{account.id}/captain/observability/release_check' do
    let(:report) do
      instance_double(
        Llm::ReleaseCheck::Report,
        to_h: {
          status: 'pass_with_warnings',
          account_id: account.id,
          checks: [
            { name: 'operational_release_gate', status: 'insufficient_data', blocking: false },
            { name: 'live_evals', status: 'not_applicable', blocking: false }
          ]
        }
      )
    end
    let(:runner) { instance_double(Llm::ReleaseCheck::Runner, call: report) }

    before do
      allow(Llm::ReleaseCheck::Runner).to receive(:new).and_return(runner)
    end

    it 'returns an admin-only release check report' do
      get "/api/v1/accounts/#{account.id}/captain/observability/release_check",
          headers: admin.create_new_auth_token,
          as: :json

      expect(response).to have_http_status(:success)
      expect(json_response).to include(
        status: 'pass_with_warnings',
        account_id: account.id
      )
      expect(json_response[:checks]).to include(
        include(name: 'operational_release_gate', status: 'insufficient_data', blocking: false),
        include(name: 'live_evals', status: 'not_applicable', blocking: false)
      )
      expect(Llm::ReleaseCheck::Runner).to have_received(:new).with(
        account: account,
        date_range: be_a(Range),
        filters: { 'feature' => 'assistant' },
        evaluation_model: nil,
        include_live_evals: false
      )
    end

    it 'passes filters and explicit live-eval parameters to the runner' do
      get "/api/v1/accounts/#{account.id}/captain/observability/release_check",
          params: {
            feature: 'copilot',
            runtime_mode: 'captain_runtime',
            session_id: 'session-1',
            flag: 'tool_failure',
            assistant_id: 101,
            since: 2.days.ago.to_i.to_s,
            until: Time.current.to_i.to_s,
            include_live: 'true',
            eval_model: 'gpt-5.2'
          },
          headers: admin.create_new_auth_token,
          as: :json

      expect(response).to have_http_status(:success)
      expect(Llm::ReleaseCheck::Runner).to have_received(:new).with(
        account: account,
        date_range: be_a(Range),
        filters: {
          'feature' => 'assistant',
          'runtime_mode' => 'captain_runtime',
          'session_id' => 'session-1',
          'flag' => 'tool_failure',
          'assistant_id' => 101
        },
        evaluation_model: 'gpt-5.2',
        include_live_evals: true
      )
    end

    it 'rejects non-admin users' do
      get "/api/v1/accounts/#{account.id}/captain/observability/release_check",
          headers: agent.create_new_auth_token,
          as: :json

      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe 'GET /api/v1/accounts/{account.id}/captain/observability/export' do
    let!(:events) do
      create_list(
        :llm_event,
        2,
        account: account,
        feature: 'assistant',
        event_name: 'llm.chat.complete',
        estimated_cost: 0.00021
      )
    end

    it 'exports matching events as JSON' do
      create(:llm_event, account: account, feature: 'copilot', event_name: 'llm.chat.complete')

      get "/api/v1/accounts/#{account.id}/captain/observability/export",
          params: { feature: 'copilot' },
          headers: admin.create_new_auth_token

      expect(response).to have_http_status(:success)
      expect(response.media_type).to eq('application/json')
      parsed = JSON.parse(response.body)
      expect(parsed['meta']).to include(
        'exported_count' => 2,
        'total_matching_count' => 2,
        'truncated' => false
      )
      expect(parsed['payload'].size).to eq(2)
    end

    it 'exports matching events as CSV' do
      create(:llm_event, account: account, feature: 'copilot', event_name: 'copilot.secret.event')

      get "/api/v1/accounts/#{account.id}/captain/observability/export",
          params: { export_format: 'csv', feature: 'copilot' },
          headers: admin.create_new_auth_token

      expect(response).to have_http_status(:success)
      expect(response.media_type).to eq('text/csv')
      expect(response.body).to include('request_id')
      expect(response.body).to include('trace_id')
      expect(response.body).to include('event_name')
      expect(response.body).to include('moderation_stage')
      expect(response.body).to include('llm.chat.complete')
      expect(response.body).not_to include('copilot.secret.event')
    end
  end

  describe 'DELETE /api/v1/accounts/{account.id}/captain/observability/event' do
    let!(:assistant_event) { create(:llm_event, account: account, feature: 'assistant') }
    let!(:other_feature_event) { create(:llm_event, account: account, feature: 'copilot') }

    it 'deletes one account-scoped AI Agent event' do
      delete "/api/v1/accounts/#{account.id}/captain/observability/event",
             headers: admin.create_new_auth_token,
             params: { event_id: assistant_event.id },
             as: :json

      expect(response).to have_http_status(:no_content)
      expect(LlmEvent.exists?(assistant_event.id)).to be(false)
      expect(LlmEvent.exists?(other_feature_event.id)).to be(true)
    end

    it 'does not delete events from another feature' do
      delete "/api/v1/accounts/#{account.id}/captain/observability/event",
             headers: admin.create_new_auth_token,
             params: { event_id: other_feature_event.id },
             as: :json

      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'DELETE /api/v1/accounts/{account.id}/captain/observability/clear' do
    let!(:assistant_event) { create(:llm_event, account: account, feature: 'assistant') }
    let!(:other_feature_event) { create(:llm_event, account: account, feature: 'copilot') }
    let!(:other_account_event) do
      create(:llm_event, account: create(:account), feature: 'assistant')
    end

    it 'clears only AI Agent events for the current account' do
      delete "/api/v1/accounts/#{account.id}/captain/observability/clear",
             headers: admin.create_new_auth_token,
             as: :json

      expect(response).to have_http_status(:no_content)
      expect(LlmEvent.exists?(assistant_event.id)).to be(false)
      expect(LlmEvent.exists?(other_feature_event.id)).to be(true)
      expect(LlmEvent.exists?(other_account_event.id)).to be(true)
    end
  end

  describe 'annotations' do
    let!(:event) { create(:llm_event, account: account, feature: 'assistant') }
    let!(:annotation) do
      create(
        :llm_event_annotation,
        account: account,
        llm_event: event,
        user: admin,
        body: 'Check provider latency on this trace.'
      )
    end

    it 'lists annotations for an event' do
      get "/api/v1/accounts/#{account.id}/captain/observability/annotations",
          params: { event_id: event.id },
          headers: admin.create_new_auth_token,
          as: :json

      expect(response).to have_http_status(:success)
      expect(json_response[:payload]).to include(
        include(
          id: annotation.id,
          body: 'Check provider latency on this trace.',
          user: include(id: admin.id, email: admin.email)
        )
      )
    end

    it 'creates annotations for an event' do
      post "/api/v1/accounts/#{account.id}/captain/observability/annotations",
           params: {
             event_id: event.id,
             body: 'Escalated to AI ops for review.'
           },
           headers: admin.create_new_auth_token,
           as: :json

      expect(response).to have_http_status(:created)
      expect(json_response[:payload]).to include(
        body: 'Escalated to AI ops for review.',
        user: include(id: admin.id)
      )
      expect(event.annotations.count).to eq(2)
    end

    it 'deletes annotations for an event' do
      delete "/api/v1/accounts/#{account.id}/captain/observability/annotations/#{annotation.id}",
             params: { event_id: event.id },
             headers: admin.create_new_auth_token,
             as: :json

      expect(response).to have_http_status(:no_content)
      expect(event.annotations.exists?(annotation.id)).to be(false)
    end

    it 'does not expose annotations for copilot events' do
      copilot_event = create(:llm_event, account: account, feature: 'copilot')

      get "/api/v1/accounts/#{account.id}/captain/observability/annotations",
          params: { event_id: copilot_event.id },
          headers: admin.create_new_auth_token,
          as: :json

      expect(response).to have_http_status(:not_found)
    end
  end
end
