# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::Evals::LiveRunJob do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account, role: :administrator) }
  let(:eval_run) do
    Llm::EvalRun.create!(
      account: account,
      user: user,
      status: 'queued',
      mode: 'live_model',
      pack_ids: ['captain.conversation_completion'],
      requested_budget_cents: 75,
      max_cases: 1
    )
  end

  it 'executes selected live packs through the shared runner and stores sanitized result' do
    suite_result = Llm::Evals::Result.new(
      suite_id: 'captain.conversation_completion',
      prompt_id: 'conversation_completion',
      prompt_sha: 'abc123',
      model: 'gpt-test',
      cases: [{ id: 'answered_question_then_thanks', status: 'pass' }]
    )
    result = Llm::Evals::CollectionResult.new(suites: [suite_result])
    runner = instance_double(Llm::Evals::Runner, call: result)
    allow(Llm::Evals::Runner).to receive(:new).and_return(runner)

    described_class.perform_now(eval_run.id)

    expect(Llm::Evals::Runner).to have_received(:new).with(
      account: account,
      pack_ids: ['captain.conversation_completion'],
      include_live: true,
      max_cases: 1
    )
    expect(eval_run.reload).to have_attributes(status: 'passed')
    expect(eval_run.result.dig('suites', 0, 'suite_id')).to eq('captain.conversation_completion')
    expect(eval_run.finished_at).to be_present
  end

  it 'marks the run failed when the runner raises' do
    allow(Llm::Evals::Runner).to receive(:new).and_raise(StandardError, 'provider unavailable token=secret123')

    expect { described_class.perform_now(eval_run.id) }.to raise_error(StandardError, 'provider unavailable token=secret123')

    expect(eval_run.reload).to have_attributes(
      status: 'failed',
      error_message: 'StandardError: provider unavailable token=[REDACTED]'
    )
  end
end
