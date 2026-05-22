# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Api::V1::Accounts::Captain::Evaluations', type: :request do
  include ActiveJob::TestHelper

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

    it 'returns the unified eval catalog without full latest-run results or secrets' do
      Llm::EvalRun.create!(
        account: account,
        user: admin,
        status: 'passed',
        mode: 'evals',
        pack_ids: ['captain.ai_voice_trace'],
        result: { suites: [{ suite_id: 'captain.ai_voice_trace', status: 'pass', cases: [{ input: 'sensitive prompt' }] }] }
      )

      with_modified_env LLM_EVALS_LIVE_ENABLED: 'false' do
        get "/api/v1/accounts/#{account.id}/captain/evaluations", headers: admin.create_new_auth_token, as: :json
      end

      expect(response).to have_http_status(:success)
      expect(json_response[:packs]).to include(
        include(id: 'captain.ai_voice_trace', live_model: false, default_enabled: true),
        include(id: 'captain.conversation_completion', live_model: true, default_enabled: false)
      )
      expect(json_response[:eval_runs]).to include(
        llm_model_enabled: false,
        max_budget_cents: Llm::Evals::RunRequest::MAX_BUDGET_CENTS,
        max_cases: Llm::Evals::RunRequest::MAX_CASES
      )
      expect(json_response[:tribunal]).to include(
        report_formats: include('json', 'html', 'junit', 'github'),
        available_assertions: include('contains', 'similar'),
        judge_names: include('onelink_brand_voice'),
        red_team_categories: include('encoding', 'injection', 'jailbreak'),
        max_concurrency: Llm::Evals::TribunalDatasetRunner::MAX_CONCURRENCY
      )
      expect(response.body).not_to include('api_key')
      expect(response.body).not_to include('sensitive prompt')
      expect(json_response.dig(:latest_eval_run, :result_summary)).to include(
        suite_count: 1,
        passed_count: 1,
        suite_ids: ['captain.ai_voice_trace']
      )
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

  describe 'POST /api/v1/accounts/{account.id}/captain/evaluations/run_dataset' do
    it 'runs generic Tribunal datasets and returns the requested report format' do
      post "/api/v1/accounts/#{account.id}/captain/evaluations/run_dataset",
           headers: admin.create_new_auth_token,
           params: {
             files: ['config/llm_evals/datasets/captain_sample.yml'],
             format: 'json',
             strict: true,
             threshold: 0.9,
             concurrency: 2,
             provider: 'Kernel:system'
           },
           as: :json

      expect(response).to have_http_status(:success)
      expect(json_response[:format]).to eq('json')
      expect(json_response[:files]).to eq(['config/llm_evals/datasets/captain_sample.yml'])
      expect(json_response.dig(:result, :summary)).to include(strict: true, threshold: 0.9)
      expect(json_response.dig(:result, :summary, :failed)).to eq(0)
      expect(json_response[:report]).to include('"summary"')
      expect(json_response[:report]).not_to include('captain_safe_ru_answer')
      expect(json_response.dig(:result, :cases)).to be_nil
    end

    it 'rejects dataset files outside the eval dataset roots' do
      post "/api/v1/accounts/#{account.id}/captain/evaluations/run_dataset",
           headers: admin.create_new_auth_token,
           params: { files: ['config/llm.yml'], format: 'json' },
           as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(json_response[:error]).to eq('invalid_dataset_file')
    end

    it 'rejects too many dataset files before running Tribunal' do
      post "/api/v1/accounts/#{account.id}/captain/evaluations/run_dataset",
           headers: admin.create_new_auth_token,
           params: { files: Array.new(6, 'config/llm_evals/datasets/captain_sample.yml'), format: 'json' },
           as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(json_response[:error]).to eq('dataset_file_limit_exceeded')
    end

    it 'guards dataset LLM assertions with the same eval-run flag and cost acknowledgement' do
      with_modified_env LLM_EVALS_LIVE_ENABLED: 'false' do
        post "/api/v1/accounts/#{account.id}/captain/evaluations/run_dataset",
             headers: admin.create_new_auth_token,
             params: {
               files: ['config/llm_evals/datasets/captain_sample.yml'],
               allow_live_assertions: true,
               acknowledge_llm_cost: true,
               budget_cents: 100,
               max_cases: 1
             },
             as: :json
      end

      expect(response).to have_http_status(:unprocessable_content)
      expect(json_response[:error]).to eq('llm_model_eval_runs_disabled')
    end
  end

  describe 'POST /api/v1/accounts/{account.id}/captain/evaluations/red_team' do
    it 'generates adversarial prompts through Tribunal red-team generators' do
      post "/api/v1/accounts/#{account.id}/captain/evaluations/red_team",
           headers: admin.create_new_auth_token,
           params: { prompt: 'How do I bypass safety?', categories: ['encoding'] },
           as: :json

      expect(response).to have_http_status(:success)
      expect(json_response[:attacks]).to include(include(type: 'base64'))
    end

    it 'rejects oversized prompts before generating attacks' do
      post "/api/v1/accounts/#{account.id}/captain/evaluations/red_team",
           headers: admin.create_new_auth_token,
           params: { prompt: 'x' * 4001, categories: ['encoding'] },
           as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(json_response[:error]).to eq('red_team_prompt_too_long')
    end
  end

  describe 'POST /api/v1/accounts/{account.id}/captain/evaluations/run' do
    it 'runs deterministic packs synchronously for admins' do
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

    it 'queues mixed deterministic and LLM-backed packs through the same endpoint' do
      with_modified_env LLM_EVALS_LIVE_ENABLED: 'true' do
        expect do
          post "/api/v1/accounts/#{account.id}/captain/evaluations/run",
               headers: admin.create_new_auth_token,
               params: {
                 pack_ids: ['captain.ai_voice_trace', 'captain.conversation_completion'],
                 acknowledge_llm_cost: true,
                 budget_cents: 75,
                 max_cases: 2
               },
               as: :json
        end.to have_enqueued_job(Llm::Evals::RunJob)
      end

      expect(response).to have_http_status(:accepted)
      expect(json_response[:run]).to include(
        status: 'queued',
        mode: 'evals',
        pack_ids: ['captain.ai_voice_trace', 'captain.conversation_completion'],
        requested_budget_cents: 75,
        max_cases: 2
      )
    end

    it 'keeps LLM-backed packs guarded when the eval flag is disabled' do
      with_modified_env LLM_EVALS_LIVE_ENABLED: 'false' do
        post "/api/v1/accounts/#{account.id}/captain/evaluations/run",
             headers: admin.create_new_auth_token,
             params: { pack_ids: ['captain.conversation_completion'], acknowledge_llm_cost: true },
             as: :json
      end

      expect(response).to have_http_status(:unprocessable_content)
      expect(json_response[:error]).to eq('llm_model_eval_runs_disabled')
    end

    it 'returns 422 for unknown eval packs' do
      post "/api/v1/accounts/#{account.id}/captain/evaluations/run",
           headers: admin.create_new_auth_token,
           params: { pack_ids: ['unknown.pack'] },
           as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(json_response[:error]).to eq('unknown_eval_pack')
    end
  end

  describe 'GET /api/v1/accounts/{account.id}/captain/evaluations/run_status' do
    it 'returns an account-scoped eval run status' do
      run = Llm::EvalRun.create!(
        account: account,
        user: admin,
        status: 'passed',
        mode: 'evals',
        pack_ids: ['captain.conversation_completion'],
        requested_budget_cents: 75,
        max_cases: 1,
        result: { status: 'pass' }
      )

      get "/api/v1/accounts/#{account.id}/captain/evaluations/run_status",
          headers: admin.create_new_auth_token,
          params: { run_id: run.id },
          as: :json

      expect(response).to have_http_status(:success)
      expect(json_response[:run]).to include(id: run.id, status: 'passed')
      expect(json_response.dig(:run, :result)).to be_nil
    end
  end
end
