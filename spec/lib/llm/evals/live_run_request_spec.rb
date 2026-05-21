# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::Evals::LiveRunRequest do
  include ActiveJob::TestHelper

  let(:account) { create(:account) }
  let(:user) { create(:user, account: account, role: :administrator) }

  around do |example|
    with_modified_env LLM_EVALS_LIVE_ENABLED: 'true' do
      example.run
    end
  end

  it 'creates an audited queued run and enqueues live eval execution when cost is acknowledged' do
    expect do
      @run = described_class.new(
        account: account,
        user: user,
        pack_ids: ['captain.conversation_completion'],
        acknowledge_live_cost: true,
        budget_cents: 75,
        max_cases: 2
      ).call
    end.to have_enqueued_job(Llm::Evals::LiveRunJob).on_queue('low')

    expect(@run).to be_persisted
    expect(@run).to have_attributes(
      account_id: account.id,
      user_id: user.id,
      status: 'queued',
      mode: 'live_model',
      pack_ids: ['captain.conversation_completion'],
      requested_budget_cents: 75,
      max_cases: 2
    )
  end

  it 'refuses live model runs unless the admin acknowledges cost' do
    expect do
      described_class.new(
        account: account,
        user: user,
        pack_ids: ['captain.conversation_completion'],
        acknowledge_live_cost: false
      ).call
    end.to raise_error(Llm::Evals::LiveRunRequest::ValidationError, 'live_eval_cost_acknowledgement_required')
  end

  it 'refuses live model runs when the live eval flag is disabled' do
    with_modified_env LLM_EVALS_LIVE_ENABLED: 'false' do
      expect do
        described_class.new(
          account: account,
          user: user,
          pack_ids: ['captain.conversation_completion'],
          acknowledge_live_cost: true
        ).call
      end.to raise_error(Llm::Evals::LiveRunRequest::ValidationError, 'live_eval_runs_disabled')
    end
  end

  it 'refuses deterministic packs on the live queue' do
    expect do
      described_class.new(
        account: account,
        user: user,
        pack_ids: ['captain.ai_voice_trace'],
        acknowledge_live_cost: true
      ).call
    end.to raise_error(Llm::Evals::LiveRunRequest::ValidationError, 'live_eval_pack_required')
  end
end
