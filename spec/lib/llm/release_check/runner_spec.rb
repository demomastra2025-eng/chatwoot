# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::ReleaseCheck::Runner do
  let(:account) { instance_double(Account, id: 7, llm_events: double('scope')) }
  let(:filters) { { feature: 'assistant' } }
  let(:runner) { described_class.new(account: account, filters: filters, evaluation_model: 'gpt-5.2', now: Time.zone.parse('2026-04-10 12:00:00')) }
  let(:events_query) { instance_double(Llm::Monitoring::EventsQuery) }
  let(:alerts_evaluator) { instance_double(Llm::Monitoring::AlertEvaluator) }
  let(:moderation_suite) { instance_double(Llm::Evals::Result, total_count: 2, passed_count: 2, failed_count: 0, error_count: 0, passed?: true, status: 'pass', to_h: { suite_id: 'moderation' }) }
  let(:tool_safety_suite) { instance_double(Llm::Evals::Result, total_count: 2, passed_count: 2, failed_count: 0, error_count: 0, passed?: true, status: 'pass', to_h: { suite_id: 'tool_safety' }) }
  let(:conversation_suite) { instance_double(Llm::Evals::Result, total_count: 1, passed_count: 1, failed_count: 0, error_count: 0, passed?: true, status: 'pass', to_h: { suite_id: 'conversation_completion' }) }

  before do
    allow(Llm::Monitoring::EventsQuery).to receive(:new).and_return(events_query)
    allow(events_query).to receive(:release_gate).and_return({ status: 'pass', checks: [] })
    allow(Llm::Monitoring::AlertEvaluator).to receive(:new).and_return(alerts_evaluator)
    allow(alerts_evaluator).to receive(:call).and_return({ status: 'ok', active_count: 0, alerts: [] })
    allow(Llm::Evals::ModerationSuite).to receive_message_chain(:new, :call).and_return(moderation_suite)
    allow(Captain::Evals::ToolSafetySuite).to receive_message_chain(:new, :call).and_return(tool_safety_suite)
    allow(Captain::Evals::ConversationCompletionSuite).to receive(:new).with(account: account, model: 'gpt-5.2').and_return(
      instance_double(Captain::Evals::ConversationCompletionSuite, call: conversation_suite)
    )
  end

  it 'combines operational gate and eval suites into one report' do
    report = runner.call

    expect(report.to_h).to include(
      status: 'pass',
      account_id: 7,
      filters: { feature: 'assistant' }
    )
    expect(report.to_h.dig(:operational, :release_gate, :status)).to eq('pass')
    expect(report.to_h.dig(:evals, :combined, :total_count)).to eq(5)
    expect(report.to_h[:checks]).to include(
      include(name: 'operational_release_gate', status: 'pass', blocking: false),
      include(name: 'deterministic_evals', status: 'pass', blocking: false),
      include(name: 'live_evals', status: 'pass', blocking: false)
    )
  end

  it 'fails when the operational gate fails even if evals pass' do
    allow(events_query).to receive(:release_gate).and_return({ status: 'fail', checks: [{ name: 'error_rate', status: 'fail' }] })

    report = runner.call

    expect(report.to_h[:status]).to eq('fail')
    expect(report.to_h[:blocking_failures]).to include(
      include(name: 'operational_release_gate', status: 'fail', blocking: true)
    )
  end

  it 'marks live evals as not_applicable when disabled by runner configuration' do
    report = described_class.new(
      account: account,
      filters: filters,
      include_live_evals: false,
      now: Time.zone.parse('2026-04-10 12:00:00')
    ).call

    expect(report.to_h[:status]).to eq('pass_with_warnings')
    expect(report.to_h[:checks]).to include(
      include(name: 'live_evals', status: 'not_applicable', blocking: false)
    )
  end
end
