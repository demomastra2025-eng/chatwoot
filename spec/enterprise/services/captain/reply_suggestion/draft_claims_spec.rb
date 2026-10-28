# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::ReplySuggestion::DraftClaims do
  let(:account) { create(:account) }
  let(:draft) { 'Спасибо, записала вас.' }
  let(:question) do
    { state: { 'draft_reply' => draft }, criteria: described_class::CRITERIA,
      instructions: described_class::INSTRUCTIONS }
  end

  def check(context = {})
    described_class.check(draft: draft, context: context, account: account)
  end

  it 'does not call a model when a mutating tool succeeded' do
    expect(Llm::DecisionChain).not_to receive(:decide)
    expect(check(captain_v2_completed_tool_results: [{ tool_name: 'create_appointment', success: true }])).to eq(:allowed)
    expect(check(captain_v2_completed_tool_results: [{ tool_name: 'update_contact', success: true }])).to eq(:allowed)
  end

  it 'does not call a model when an approval card is pending' do
    expect(Llm::DecisionChain).not_to receive(:decide)
    expect(check(captain_suggestion_pending_actions: [{ tool_name: 'cancel_appointment', status: 'pending' }])).to eq(:allowed)
  end

  it 'blocks when the probability of done is at the threshold' do
    allow(Llm::DecisionChain).to receive(:decide).with(feature: :reply_claim_check, account: account, question: question)
                                                 .and_return(instance_double(Llm::DecisionChain::Result, choice: 'done', confidence: 0.5,
                                                                                                         probabilities: { 'done' => 0.5 }))
    expect(check).to eq(:done)
  end

  it 'allows a draft below the threshold' do
    allow(Llm::DecisionChain).to receive(:decide).with(feature: :reply_claim_check, account: account, question: question)
                                                 .and_return(instance_double(Llm::DecisionChain::Result, choice: 'not_done', confidence: 0.51,
                                                                                                         probabilities: { 'done' => 0.49 }))
    expect(check).to eq(:allowed)
  end

  it 'sends a draft to a human when the chain is exhausted' do
    allow(Llm::DecisionChain).to receive(:decide).and_raise(Llm::DecisionChain::ExhaustedError.new(feature: :reply_claim_check, attempts: []))
    expect(check).to eq(:unavailable)
  end

  it 'does not let a failed mutating call count as evidence' do
    expect(Llm::DecisionChain).to receive(:decide).and_return(instance_double(Llm::DecisionChain::Result, choice: 'done', confidence: 0.9,
                                                                                                          probabilities: { 'done' => 0.9 }))
    expect(check(captain_v2_completed_tool_results: [{ tool_name: 'cancel_appointment', success: false }])).to eq(:done)
  end

  it 'does not let a successful lookup count as mutation evidence' do
    expect(Llm::DecisionChain).to receive(:decide).and_return(instance_double(Llm::DecisionChain::Result, choice: 'done', confidence: 0.9,
                                                                                                          probabilities: { 'done' => 0.9 }))
    expect(check(captain_v2_completed_tool_results: [{ tool_name: 'list_my_appointments', success: true }])).to eq(:done)
  end
end
