# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::BudgetEvaluator do
  let(:account) { create(:account) }
  let(:request) do
    Llm::FeatureRequest.new(
      feature: :captain_agent,
      account: account,
      model: 'openai/gpt-4o',
      messages: [{ role: 'user', content: 'hello' }]
    )
  end

  describe '.evaluate' do
    it 'allows requests when no active policy applies' do
      decision = described_class.evaluate(request: request, model: 'openai/gpt-4o')

      expect(decision).to be_allowed
      expect(decision.reason).to eq('no_policy')
    end

    it 'blocks hard-stop requests when the local daily budget is exhausted' do
      create(:llm_budget_policy, account: account, daily_budget: 1.0, monthly_budget: nil, hard_stop: true)
      create(:llm_usage_event, account: account, estimated_cost: 1.01, occurred_at: Time.zone.now)

      decision = described_class.evaluate(request: request, model: 'openai/gpt-4o')

      expect(decision).not_to be_allowed
      expect(decision.reason).to eq('daily_budget_exceeded')
      expect(decision.limit.to_f).to eq(1.0)
      expect(decision.current_spend.to_f).to eq(1.01)
    end

    it 'evaluates OpenRouter budgets with the same provider scope as the usage dashboard' do
      create(:llm_budget_policy, account: account, daily_budget: 1.0, hard_stop: true)
      create(:llm_usage_event, account: account, provider: 'gemini', estimated_cost: 5.0, occurred_at: Time.zone.now)
      create(:llm_usage_event, account: account, provider: 'openrouter', estimated_cost: 0.25, occurred_at: Time.zone.now)

      decision = described_class.evaluate(request: request, model: 'openai/gpt-4o')

      expect(decision).to be_allowed
      expect(decision.current_spend.to_f).to eq(0.25)
    end

    it 'warns but allows when spend crosses a soft warning threshold' do
      create(:llm_budget_policy, account: account, daily_budget: 1.0, warning_threshold: 0.8, hard_stop: false)
      create(:llm_usage_event, account: account, estimated_cost: 0.81, occurred_at: Time.zone.now)

      decision = described_class.evaluate(request: request, model: 'openai/gpt-4o')

      expect(decision).to be_allowed
      expect(decision.reason).to eq('daily_budget_warning')
      expect(decision.warning?).to be true
    end

    it 'prefers feature-specific account policy over global default policy using equivalent feature keys' do
      create(:llm_budget_policy, scope_type: 'global', account: nil, daily_budget: 1.0, hard_stop: true)
      create(:llm_budget_policy, account: account, feature: 'captain_agent', daily_budget: 3.0, hard_stop: true)
      create(:llm_usage_event, account: account, feature: 'assistant', estimated_cost: 0.25, occurred_at: Time.zone.now)
      create(:llm_usage_event, account: account, feature: 'captain_agent', estimated_cost: 1.50, occurred_at: Time.zone.now)

      decision = described_class.evaluate(request: request, model: 'openai/gpt-4o')

      expect(decision).to be_allowed
      expect(decision.reason).to eq('within_budget')
      expect(decision.policy.feature).to eq('captain_agent')
      expect(decision.current_spend.to_f).to eq(1.75)
    end

    it 'counts native endpoint alias usage for feature-specific budget policies' do
      embedding_request = Llm::FeatureRequest.new(
        feature: :help_center_search,
        account: account,
        model: 'openai/text-embedding-3-small',
        input: ['hello']
      )
      create(:llm_budget_policy, account: account, feature: 'embedding', daily_budget: 1.0, hard_stop: true)
      create(:llm_usage_event, account: account, feature: 'help_center_search', estimated_cost: 1.01, occurred_at: Time.zone.now)

      decision = described_class.evaluate(request: embedding_request, model: 'openai/text-embedding-3-small')

      expect(decision).not_to be_allowed
      expect(decision.reason).to eq('daily_budget_exceeded')
      expect(decision.current_spend.to_f).to eq(1.01)
    end

    it 'still enforces account-wide caps when a feature-specific account policy exists' do
      create(:llm_budget_policy, account: account, feature: nil, daily_budget: 1.0, hard_stop: true)
      create(:llm_budget_policy, account: account, feature: 'captain_agent', daily_budget: 5.0, hard_stop: true)
      create(:llm_usage_event, account: account, feature: 'assistant', estimated_cost: 1.50, occurred_at: Time.zone.now)
      create(:llm_usage_event, account: account, feature: 'captain_agent', estimated_cost: 0.50, occurred_at: Time.zone.now)

      decision = described_class.evaluate(request: request, model: 'openai/gpt-4o')

      expect(decision).not_to be_allowed
      expect(decision.policy.feature).to be_nil
      expect(decision.current_spend.to_f).to eq(2.0)
    end

    it 'falls back to global policy when an account-specific row has no budget limits' do
      create(:llm_budget_policy, account: account, feature: 'captain_agent', daily_budget: nil, monthly_budget: nil)
      create(:llm_budget_policy, scope_type: 'global', account: nil, daily_budget: 1.0, hard_stop: true)
      create(:llm_usage_event, account: account, feature: 'captain_agent', estimated_cost: 1.50, occurred_at: Time.zone.now)

      decision = described_class.evaluate(request: request, model: 'openai/gpt-4o')

      expect(decision).not_to be_allowed
      expect(decision.policy.scope_type).to eq('global')
    end

    it 'does not aggregate all accounts when evaluating accountless feature requests' do
      accountless_request = Llm::FeatureRequest.new(feature: :moderation, account: nil, model: 'openai/gpt-oss-safeguard-20b')
      create(:llm_budget_policy, scope_type: 'global', account: nil, daily_budget: 0.1, hard_stop: true)
      create(:llm_usage_event, account: account, feature: 'moderation', estimated_cost: 5.0, occurred_at: Time.zone.now)

      decision = described_class.evaluate(request: accountless_request, model: 'openai/gpt-oss-safeguard-20b')

      expect(decision).to be_allowed
      expect(decision.reason).to eq('no_policy')
    end
  end

  describe '.evaluate!' do
    it 'raises a typed budget error and publishes a redacted budget event before provider execution' do
      create(:llm_budget_policy, account: account, daily_budget: 1.0, hard_stop: true)
      create(:llm_usage_event, account: account, estimated_cost: 1.01, occurred_at: Time.zone.now)
      events = []
      subscriber = ActiveSupport::Notifications.subscribe('llm.budget.blocked') do |*args|
        events << ActiveSupport::Notifications::Event.new(*args)
      end

      expect do
        described_class.evaluate!(request: request, model: 'openai/gpt-4o')
      end.to raise_error(Llm::BudgetEvaluator::BudgetExceededError, /daily_budget_exceeded/)

      expect(events.last.payload).to include(
        'account_id' => account.id,
        'feature' => 'captain_agent',
        'provider' => 'openrouter',
        'status' => 'blocked',
        'blocked' => true,
        'error' => true,
        'error_code' => described_class::ERROR_CODE
      )
      expect(events.last.payload['budget_decision']).to include(reason: 'daily_budget_exceeded')
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
    end

    it 'publishes warning events without blocking provider execution' do
      create(:llm_budget_policy, account: account, daily_budget: 1.0, warning_threshold: 0.8, hard_stop: false)
      create(:llm_usage_event, account: account, estimated_cost: 0.81, occurred_at: Time.zone.now)
      events = []
      subscriber = ActiveSupport::Notifications.subscribe('llm.budget.warning') do |*args|
        events << ActiveSupport::Notifications::Event.new(*args)
      end

      decision = described_class.evaluate!(request: request, model: 'openai/gpt-4o')

      expect(decision).to be_allowed
      expect(events.last.payload).to include(
        'account_id' => account.id,
        'feature' => 'captain_agent',
        'status' => 'warning',
        'blocked' => false,
        'error' => false,
        'error_code' => described_class::WARNING_CODE
      )
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
    end
  end
end
