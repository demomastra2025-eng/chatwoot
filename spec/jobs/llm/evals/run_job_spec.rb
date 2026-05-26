# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::Evals::RunJob do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account, role: :administrator) }
  let(:eval_run) do
    Llm::EvalRun.create!(
      account: account,
      user: user,
      status: 'queued',
      mode: 'evals',
      pack_ids: ['captain.ai_voice_trace', 'captain.conversation_completion'],
      requested_budget_cents: 75,
      max_cases: 1
    )
  end

  it 'executes selected eval packs through the shared runner and stores sanitized result' do
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
      pack_ids: ['captain.ai_voice_trace', 'captain.conversation_completion'],
      include_live: true,
      max_cases: 1
    )
    expect(eval_run.reload).to have_attributes(status: 'passed')
    expect(eval_run.result.dig('suites', 0, 'suite_id')).to eq('captain.conversation_completion')
    expect(eval_run.result.dig('suites', 0, 'cases')).to be_nil
    expect(eval_run.result.to_json).not_to include('answered_question_then_thanks')
    expect(eval_run.finished_at).to be_present
  end

  it 'marks the run failed when the runner raises' do
    allow(Llm::Evals::Runner).to receive(:new).and_raise(StandardError, 'provider unavailable token=secret123')

    expect { described_class.perform_now(eval_run.id) }.not_to raise_error

    expect(eval_run.reload).to have_attributes(
      status: 'failed',
      error_message: 'StandardError: provider unavailable token=[REDACTED]'
    )
  end

  it 'does not re-run terminal eval runs' do
    eval_run.update!(status: 'failed', finished_at: 1.hour.ago, error_message: 'already failed')
    allow(Llm::Evals::Runner).to receive(:new)

    described_class.perform_now(eval_run.id)

    expect(Llm::Evals::Runner).not_to have_received(:new)
    expect(eval_run.reload.error_message).to eq('already failed')
  end
end
