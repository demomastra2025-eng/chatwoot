# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::ConversationCompletionEvaluator do
  let(:account) do
    create(:account).tap { |record| record.enable_features('captain_tasks') }
  end
  let(:evaluator) do
    described_class.new(
      account: account,
      messages: [{ role: 'user', content: 'Can I book for tomorrow?' }, { role: 'assistant', content: 'Yes.' }]
    )
  end

  it 'marks a parsed completion result as evaluated for follow-up gating' do
    allow(evaluator).to receive(:make_api_call).and_return(
      error: nil,
      message: { 'complete' => false, 'reason' => 'The customer has not confirmed the time.', 'message' => 'Please confirm your preferred time.' }
    )

    expect(evaluator.perform).to eq(
      evaluated: true,
      complete: false,
      reason: 'The customer has not confirmed the time.',
      message: 'Please confirm your preferred time.'
    )
  end

  it 'marks malformed provider output as unevaluated instead of retrying it as a valid incomplete result' do
    allow(evaluator).to receive(:make_api_call).and_return(error: nil, message: { 'complete' => 'false' })

    expect(evaluator.perform).to include(evaluated: false, complete: false, reason: 'Invalid completion value')
  end
end
