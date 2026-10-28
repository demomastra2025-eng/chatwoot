# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::ReplySuggestion::DraftClaims do
  let(:account) { create(:account) }
  let(:draft) { 'Спасибо, записала вас.' }
  let(:question) { { state: { 'draft_reply' => draft }, questions: described_class::QUESTIONS } }
  let(:completed_answer) { Llm::OpenRouterDecisionClient::Answer.new(choice: 'not_done', confidence: 0.9, probabilities: { 'done' => 0.1 }) }
  let(:denial_answer) { Llm::OpenRouterDecisionClient::Answer.new(choice: 'other', confidence: 0.9, probabilities: { 'no_appointment' => 0.1 }) }
  let(:answers) { { 'completed_action' => completed_answer, 'no_appointment' => denial_answer } }
  let(:result) { Llm::DecisionChain::Result.new(answers: answers) }

  before { allow(Llm::DecisionChain).to receive(:decide).and_return(result) }

  def check(context = {})
    described_class.check(draft: draft, context: context, account: account)
  end

  it 'allows a completed claim when a mutating tool succeeded, while still checking for a false denial' do
    completed_answer.probabilities = { 'done' => 0.9 }
    expect(check(captain_v2_completed_tool_results: [{ tool_name: 'create_appointment', success: true }])).to eq(:allowed)
  end

  it 'does not call a model when an approval card is pending' do
    completed_answer.probabilities = { 'done' => 0.9 }
    expect(check(captain_suggestion_pending_actions: [{ tool_name: 'cancel_appointment', status: 'pending' }])).to eq(:allowed)
  end

  it 'blocks when the probability of done is at the threshold' do
    completed_answer.probabilities = { 'done' => 0.5 }
    expect(check).to eq(:done)
    expect(Llm::DecisionChain).to have_received(:decide).with(feature: :reply_claim_check, account: account, question: question)
  end

  it 'allows a draft below the threshold' do
    completed_answer.probabilities = { 'done' => 0.49 }
    expect(check).to eq(:allowed)
  end

  it 'sends a draft to a human when the chain is exhausted' do
    allow(Llm::DecisionChain).to receive(:decide).and_raise(Llm::DecisionChain::ExhaustedError.new(feature: :reply_claim_check, attempts: []))
    expect(check).to eq(:unavailable)
  end

  it 'does not let a failed mutating call count as evidence' do
    completed_answer.probabilities = { 'done' => 0.9 }
    expect(check(captain_v2_completed_tool_results: [{ tool_name: 'cancel_appointment', success: false }])).to eq(:done)
  end

  it 'does not let a successful lookup count as mutation evidence' do
    completed_answer.probabilities = { 'done' => 0.9 }
    expect(check(captain_v2_completed_tool_results: [{ tool_name: 'list_my_appointments', success: true }])).to eq(:done)
  end

  it 'blocks a false no-appointment claim using this patient future preload' do
    denial_answer.probabilities = { 'no_appointment' => 0.9 }
    appointment = { date: 2.days.from_now.strftime('%d.%m.%Y'), time: '13:30', status: 'scheduled', own: true }
    expect(check(suggestion_preload: { appointments: [appointment] })).to eq(:no_appointment)
    expect(check(suggestion_preload: { appointments: [appointment.merge(own: false)] })).to eq(:allowed)
  end

  it 'blocks a false no-appointment claim using a list_my_appointments lookup from this run' do
    denial_answer.probabilities = { 'no_appointment' => 0.9 }
    appointment = { date: 2.days.from_now.strftime('%d.%m.%Y'), time: '13:30', status: 'scheduled' }
    context = { captain_suggestion_read_result_cache:
      { 'read-1' => { tool: 'list_my_appointments', result: { appointments: [appointment] }.to_json } } }
    expect(check(context)).to eq(:no_appointment)
  end

  it 'ignores past and cancelled appointments' do
    denial_answer.probabilities = { 'no_appointment' => 0.9 }
    past = { date: 2.days.ago.strftime('%d.%m.%Y'), time: '13:30', status: 'scheduled', own: true }
    cancelled = past.merge(date: 2.days.from_now.strftime('%d.%m.%Y'), status: 'cancelled')
    expect(check(suggestion_preload: { appointments: [past, cancelled] })).to eq(:allowed)
  end
end
