# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::BudgetEvaluator do
  let(:account) { create(:account) }
  let(:request) do
    Llm::FeatureRequest.new(feature: :captain_agent, account: account, model: 'openai/gpt-4o')
  end

  it 'allows a request even when a stored hard-stop policy is exceeded' do
    create(:llm_budget_policy, account: account, daily_budget: 0, hard_stop: true)

    expect(Llm::UsageLedger).not_to receive(:spend)
    decision = described_class.evaluate!(request: request)

    expect(decision).to be_allowed
    expect(decision.reason).to eq('no_limit')
  end
end
