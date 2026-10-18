# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Accounts::PlanDrift do
  let(:account) { create(:account).tap { |record| record.disable_features!(*Featurable::FEATURE_NAMES) } }

  def apply(modules = [])
    Accounts::ApplyPlan.new(account: account, modules: modules).call
  end

  it 'is nil for an account that has no plan' do
    account.enable_features!('crm', 'campaigns')

    expect(described_class.call(account)).to be_nil
  end

  it 'is empty right after a plan was applied' do
    apply(%w[ai_agents])

    expect(described_class.call(account)).to eq(extra: [], missing: [])
  end

  it 'lists a flag that was switched on by hand as extra' do
    apply
    account.enable_features!('campaigns', 'sla', 'captain_scheduling_grounding_guard')

    expect(described_class.call(account)[:extra]).to match_array(%w[campaigns sla captain_scheduling_grounding_guard])
    expect(described_class.call(account)[:missing]).to be_empty
  end

  it 'lists a flag that was switched off by hand as missing' do
    apply(%w[quality])
    account.disable_features!('crm', 'sla')

    expect(described_class.call(account)).to eq(extra: [], missing: %w[crm sla])
  end

  it 'does not count a deprecated flag as changed by hand' do
    # A plan applied while the Agent Bots were still part of the base left the flag on.
    apply
    account.enable_features!('agent_bots', 'channel_twitter')

    expect(described_class.call(account)).to eq(extra: [], missing: [])
  end

  it 'still lists a flag of never_enabled that is not deprecated' do
    apply
    account.enable_features!('agent_bots', 'custom_roles')

    expect(described_class.call(account)[:extra]).to eq(%w[custom_roles])
  end

  it 'does not look at the internal flags' do
    apply
    account.enable_features!('ip_lookup', 'communication_threads')
    account.disable_features!('inbox_view')

    expect(described_class.call(account)).to eq(extra: [], missing: [])
  end

  it 'follows the modules that were applied, not the current ones' do
    apply(%w[broadcasts])
    account.disable_features!('campaigns')

    expect(described_class.call(account)).to eq(extra: [], missing: %w[campaigns])
  end

  it 'ignores a stored module that the plans no longer know' do
    apply
    account.update!(custom_attributes: account.custom_attributes.merge('plan_modules' => %w[ghost quality]))
    account.enable_features!('sla', 'audit_logs', 'csat_review_notes')

    expect(described_class.call(account)).to eq(extra: [], missing: [])
  end

  it 'does not count what a running trial granted as changed by hand' do
    apply
    account.activate_trial!(3)

    expect(described_class.call(account.reload)).to eq(extra: [], missing: [])
  end

  it 'counts the trial features as extra once the trial is over and they are still on' do
    apply
    account.activate_trial!(3)
    account.expire_trial!
    account.enable_features!('captain_integration')

    expect(described_class.call(account.reload)).to eq(extra: %w[captain_integration], missing: [])
  end
end
