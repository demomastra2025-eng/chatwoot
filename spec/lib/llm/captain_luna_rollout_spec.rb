# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::CaptainLunaRollout do
  before do
    InstallationConfig.find_or_initialize_by(name: 'CAPTAIN_AI_AGENT_DEFAULT_MODEL').update!(value: 'openai/gpt-5.6-luna')
    InstallationConfig.find_or_initialize_by(name: 'CAPTAIN_OPENROUTER_API_KEY').update!(value: 'test-key')
  end

  it 'updates only the assistant model while preserving other settings' do
    old_account = create(:account, captain_models: { 'assistant' => 'openai/gpt-5.6-luna', 'copilot' => 'gpt-5.4' })
    unset_account = create(:account, captain_models: { 'copilot' => 'gpt-5.4' })
    already_updated = create(:account, captain_models: { 'assistant' => 'openai/gpt-6-luna' })
    scope = Account.where(id: [old_account.id, unset_account.id, already_updated.id])
    plan = described_class.plan(scope: scope)

    expect(described_class.apply!(plan, scope: scope)).to eq(2)
    expect(old_account.reload.captain_models).to include('assistant' => 'openai/gpt-6-luna', 'copilot' => 'gpt-5.4')
    expect(unset_account.reload.captain_models).to include('assistant' => 'openai/gpt-6-luna', 'copilot' => 'gpt-5.4')
    expect(already_updated.reload.captain_models['assistant']).to eq('openai/gpt-6-luna')
    expect(Llm::Config.model_for(feature: :assistant, account: old_account)).to eq('openai/gpt-6-luna')
    expect(Llm::Config.model_for(feature: :assistant, account: unset_account)).to eq('openai/gpt-6-luna')
    expect(InstallationConfig.find_by!(name: 'CAPTAIN_AI_AGENT_DEFAULT_MODEL').value).to eq('openai/gpt-6-luna')
  end

  it 'restores only accounts whose assistant model was changed' do
    old_account = create(:account, captain_models: { 'assistant' => 'openai/gpt-5.6-luna', 'copilot' => 'gpt-5.4' })
    unset_account = create(:account, captain_models: { 'copilot' => 'gpt-5.4' })
    already_updated = create(:account, captain_models: { 'assistant' => 'openai/gpt-6-luna' })
    scope = Account.where(id: [old_account.id, unset_account.id, already_updated.id])
    plan = JSON.parse(described_class.plan(scope: scope).to_json)
    described_class.apply!(plan, scope: scope)

    expect(described_class.rollback!(plan)).to eq(2)
    expect(old_account.reload.captain_models).to include('assistant' => 'openai/gpt-5.6-luna', 'copilot' => 'gpt-5.4')
    expect(unset_account.reload.captain_models).to include('copilot' => 'gpt-5.4')
    expect(unset_account.captain_models).not_to have_key('assistant')
    expect(already_updated.reload.captain_models['assistant']).to eq('openai/gpt-6-luna')
    expect(Llm::Config.model_for(feature: :assistant, account: unset_account)).to eq('openai/gpt-5.6-luna')
    expect(InstallationConfig.find_by!(name: 'CAPTAIN_AI_AGENT_DEFAULT_MODEL').value).to eq('openai/gpt-5.6-luna')
  end

  it 'rejects a stale plan without changing other accounts' do
    first = create(:account, captain_models: { 'assistant' => 'openai/gpt-5.6-luna' })
    second = create(:account, captain_models: { 'assistant' => 'openai/gpt-5.6-luna' })
    scope = Account.where(id: [first.id, second.id])
    plan = described_class.plan(scope: scope)
    second.update!(captain_models: { 'assistant' => 'openai/gpt-6-luna' })

    expect { described_class.apply!(plan, scope: scope) }.to raise_error(described_class::StalePlan)
    expect(first.reload.captain_models['assistant']).to eq('openai/gpt-5.6-luna')
  end

  [
    { 'openrouter_allow_model_fallbacks' => false },
    { 'privacy_profile' => 'zdr_required' }
  ].each do |runtime_settings|
    it "rejects an account whose runtime disables the Luna route: #{runtime_settings.keys.first}" do
      account = create(:account, captain_models: { 'assistant' => 'openai/gpt-5.6-luna' }, captain_runtime: runtime_settings)
      scope = Account.where(id: account.id)
      plan = described_class.plan(scope: scope)

      expect { described_class.apply!(plan, scope: scope) }.to raise_error(described_class::StalePlan, /fallback/)
      expect(account.reload.captain_models['assistant']).to eq('openai/gpt-5.6-luna')
      expect(InstallationConfig.find_by!(name: 'CAPTAIN_AI_AGENT_DEFAULT_MODEL').value).to eq('openai/gpt-5.6-luna')
    end
  end

  it 'rejects a plan when the agent-only default changed after the snapshot' do
    account = create(:account, captain_models: { 'assistant' => 'openai/gpt-5.6-luna' })
    scope = Account.where(id: account.id)
    plan = described_class.plan(scope: scope)
    InstallationConfig.find_by!(name: 'CAPTAIN_AI_AGENT_DEFAULT_MODEL').update!(value: 'openai/gpt-5.4-mini')

    expect { described_class.apply!(plan, scope: scope) }.to raise_error(described_class::StalePlan)
    expect(account.reload.captain_models['assistant']).to eq('openai/gpt-5.6-luna')
  end

  it 'rejects a snapshot taken after the Luna 6 default was already installed' do
    InstallationConfig.find_by!(name: 'CAPTAIN_AI_AGENT_DEFAULT_MODEL').update!(value: 'openai/gpt-6-luna')

    expect { described_class.plan(scope: Account.where(id: create(:account).id)) }
      .to raise_error(described_class::StalePlan)
  end

  it 'restores the effective old model when the agent-only default did not previously exist' do
    InstallationConfig.find_by!(name: 'CAPTAIN_AI_AGENT_DEFAULT_MODEL').destroy!
    InstallationConfig.find_or_initialize_by(name: 'CAPTAIN_DEFAULT_MODEL').update!(value: 'openai/gpt-5.6-luna')
    account = create(:account, captain_models: {})
    scope = Account.where(id: account.id)
    plan = described_class.plan(scope: scope)

    described_class.apply!(plan, scope: scope)
    described_class.rollback!(plan)

    expect(InstallationConfig.find_by(name: 'CAPTAIN_AI_AGENT_DEFAULT_MODEL')).to be_nil
    expect(Llm::Config.model_for(feature: :assistant, account: account.reload)).to eq('openai/gpt-5.6-luna')
  end

  it 'refuses a snapshot when unset accounts already inherit the new catalog default' do
    %w[CAPTAIN_AI_AGENT_DEFAULT_MODEL CAPTAIN_DEFAULT_MODEL CAPTAIN_OPEN_AI_MODEL].each do |name|
      InstallationConfig.find_by(name: name)&.destroy!
    end
    account = create(:account, captain_models: {})

    expect { described_class.plan(scope: Account.where(id: account.id)) }.to raise_error(described_class::StalePlan)
  end

  it 'does not partially roll back when an account model was changed after the rollout' do
    first = create(:account, captain_models: { 'assistant' => 'openai/gpt-5.6-luna' })
    second = create(:account, captain_models: { 'assistant' => 'openai/gpt-5.6-luna' })
    scope = Account.where(id: [first.id, second.id])
    plan = described_class.plan(scope: scope)
    described_class.apply!(plan, scope: scope)
    second.reload.update!(captain_models: { 'assistant' => 'openai/gpt-5.6-luna' })

    expect { described_class.rollback!(plan) }.to raise_error(described_class::StalePlan)
    expect(first.reload.captain_models['assistant']).to eq('openai/gpt-6-luna')
    expect(second.reload.captain_models['assistant']).to eq('openai/gpt-5.6-luna')
  end
end
