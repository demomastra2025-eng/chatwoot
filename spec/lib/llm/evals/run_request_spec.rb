# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::Evals::RunRequest do
  include ActiveJob::TestHelper

  let(:account) { create(:account) }
  let(:user) { create(:user, account: account, role: :administrator) }

  around do |example|
    with_modified_env LLM_EVALS_LIVE_ENABLED: 'true' do
      example.run
    end
  end

  it 'creates one audited queued eval run for mixed deterministic and LLM-backed packs' do
    run = nil
    expect do
      run = described_class.new(
        account: account,
        user: user,
        pack_ids: ['captain.ai_voice_trace', 'captain.conversation_completion'],
        acknowledge_live_cost: true,
        budget_cents: 75,
        max_cases: 2
      ).call
    end.to have_enqueued_job(Llm::Evals::RunJob).on_queue('low')

    expect(run).to be_persisted
    expect(run).to have_attributes(
      account_id: account.id,
      user_id: user.id,
      status: 'queued',
      mode: 'evals',
      pack_ids: ['captain.ai_voice_trace', 'captain.conversation_completion'],
      requested_budget_cents: 75,
      max_cases: 2
    )
    expect(run.metadata).to include('queued_llm_model_run' => true)
  end

  it 'refuses LLM-backed eval packs unless the admin acknowledges cost' do
    expect do
      described_class.new(
        account: account,
        user: user,
        pack_ids: ['captain.conversation_completion'],
        acknowledge_live_cost: false
      ).call
    end.to raise_error(Llm::Evals::RunRequest::ValidationError, 'llm_model_eval_cost_acknowledgement_required')
  end

  it 'refuses LLM-backed eval packs when the eval flag is disabled' do
    with_modified_env LLM_EVALS_LIVE_ENABLED: 'false' do
      expect do
        described_class.new(
          account: account,
          user: user,
          pack_ids: ['captain.conversation_completion'],
          acknowledge_live_cost: true
        ).call
      end.to raise_error(Llm::Evals::RunRequest::ValidationError, 'llm_model_eval_runs_disabled')
    end
  end

  it 'refuses LLM-backed eval packs when estimated case cost exceeds budget' do
    expect do
      described_class.new(
        account: account,
        user: user,
        pack_ids: ['captain.conversation_completion'],
        acknowledge_live_cost: true,
        budget_cents: 25,
        max_cases: 2
      ).call
    end.to raise_error(Llm::Evals::RunRequest::ValidationError, 'llm_model_eval_budget_exceeded')
  end

  it 'refuses a second active LLM-backed eval run for the same account' do
    Llm::EvalRun.create!(
      account: account,
      user: user,
      status: 'queued',
      mode: 'evals',
      pack_ids: ['captain.conversation_completion'],
      requested_budget_cents: 75,
      max_cases: 2,
      metadata: { queued_llm_model_run: true }
    )

    expect do
      described_class.new(
        account: account,
        user: user,
        pack_ids: ['captain.conversation_completion'],
        acknowledge_live_cost: true,
        budget_cents: 75,
        max_cases: 2
      ).call
    end.to raise_error(Llm::Evals::RunRequest::ValidationError, 'llm_model_eval_already_running')
  end

  it 'can queue deterministic-only eval packs without LLM cost controls' do
    run = nil
    expect do
      run = described_class.new(
        account: account,
        user: user,
        pack_ids: ['captain.ai_voice_trace'],
        acknowledge_live_cost: false
      ).call
    end.to have_enqueued_job(Llm::Evals::RunJob)

    expect(run).to have_attributes(
      mode: 'evals',
      pack_ids: ['captain.ai_voice_trace'],
      requested_budget_cents: 0,
      max_cases: nil
    )
  end
end
