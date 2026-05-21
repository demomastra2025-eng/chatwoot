# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Api::V1::Accounts::Captain::Evaluations', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }

  def json_response
    JSON.parse(response.body, symbolize_names: true)
  end

  describe 'GET /api/v1/accounts/{account.id}/captain/evaluations' do
    it 'requires an authenticated admin' do
      get "/api/v1/accounts/#{account.id}/captain/evaluations", headers: agent.create_new_auth_token, as: :json

      expect(response).to have_http_status(:unauthorized)
    end

    it 'returns the eval catalog without secrets' do
      get "/api/v1/accounts/#{account.id}/captain/evaluations", headers: admin.create_new_auth_token, as: :json

      expect(response).to have_http_status(:success)
      expect(json_response[:packs]).to include(
        include(id: 'captain.ai_voice_trace', live_model: false, default_enabled: true),
        include(id: 'captain.conversation_completion', live_model: true, default_enabled: false)
      )
      expect(response.body).not_to include('api_key')
    end
  end

  describe 'POST /api/v1/accounts/{account.id}/captain/evaluations/import_conversation' do
    it 'exports a sanitized AI Voice trace fixture preview for admins' do
      exporter = instance_double(
        Llm::Evals::AiVoiceTraceExporter,
        call: { case: { id: 'conversation_481_ai_voice_trace' }, yaml: "cases:\n  - id: conversation_481_ai_voice_trace\n" }
      )
      allow(Llm::Evals::AiVoiceTraceExporter).to receive(:new).and_return(exporter)

      post "/api/v1/accounts/#{account.id}/captain/evaluations/import_conversation",
           headers: admin.create_new_auth_token,
           params: { inbox_id: 57, display_id: 481 },
           as: :json

      expect(response).to have_http_status(:success)
      expect(Llm::Evals::AiVoiceTraceExporter).to have_received(:new).with(account: account, inbox_id: 57, display_id: 481)
      expect(json_response[:case]).to include(id: 'conversation_481_ai_voice_trace')
      expect(json_response[:yaml]).to include('conversation_481_ai_voice_trace')
    end
  end

  describe 'POST /api/v1/accounts/{account.id}/captain/evaluations/run' do
    it 'runs deterministic packs for admins' do
      report = Llm::Evals::CollectionResult.new(suites: [
                                                  Llm::Evals::Result.new(
                                                    suite_id: 'captain.ai_voice_trace',
                                                    prompt_id: nil,
                                                    prompt_sha: nil,
                                                    model: nil,
                                                    cases: [{ id: 'healthy', status: 'pass' }]
                                                  )
                                                ])
      runner = instance_double(Llm::Evals::Runner, call: report)
      allow(Llm::Evals::Runner).to receive(:new).and_return(runner)

      post "/api/v1/accounts/#{account.id}/captain/evaluations/run",
           headers: admin.create_new_auth_token,
           params: { pack_ids: ['captain.ai_voice_trace'] },
           as: :json

      expect(response).to have_http_status(:success)
      expect(Llm::Evals::Runner).to have_received(:new).with(
        account: account,
        pack_ids: ['captain.ai_voice_trace'],
        include_live: false
      )
      expect(json_response.dig(:result, :suites).first).to include(suite_id: 'captain.ai_voice_trace')
    end

    it 'blocks live model execution from the UI endpoint until queueing and spend controls exist' do
      post "/api/v1/accounts/#{account.id}/captain/evaluations/run",
           headers: admin.create_new_auth_token,
           params: { include_live: true, pack_ids: ['captain.conversation_completion'] },
           as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(json_response[:error]).to eq('live_eval_runs_not_enabled')
    end

    it 'blocks live packs even when include_live is omitted' do
      post "/api/v1/accounts/#{account.id}/captain/evaluations/run",
           headers: admin.create_new_auth_token,
           params: { pack_ids: ['captain.conversation_completion'] },
           as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(json_response[:error]).to eq('live_eval_runs_not_enabled')
    end
  end
end
