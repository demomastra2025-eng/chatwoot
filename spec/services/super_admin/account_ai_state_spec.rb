require 'rails_helper'

RSpec.describe SuperAdmin::AccountAiState do
  let(:account) { create(:account) }
  let(:state) { described_class.new(account) }
  let(:platform_model) { 'openai/gpt-6-luna' }

  def stub_models(platform:, account_model: platform)
    allow(Llm::Config).to receive(:model_for).with(feature: 'assistant').and_return(platform)
    allow(Llm::Config).to receive(:model_for).with(feature: 'assistant', account: account).and_return(account_model)
  end

  describe 'the model' do
    it 'is the model of the platform for an account that chose nothing' do
      stub_models(platform: platform_model)

      expect(state.model_id).to eq(platform_model)
      expect(state.model_name).to eq(SuperAdmin::AiModelOptions.name_of(platform_model))
      expect(state).not_to be_own_model
    end

    it 'is the model the account chose when the agents really answer with it' do
      account.update_columns(settings: { 'captain_models' => { 'assistant' => 'openai/gpt-5.4' } }) # rubocop:disable Rails/SkipsModelValidations
      stub_models(platform: platform_model, account_model: 'openai/gpt-5.4')

      expect(state.model_id).to eq('openai/gpt-5.4')
      expect(state).to be_own_model
    end

    it 'counts a choice that no longer works as the platform model: the agents answer with the platform one' do
      account.update_columns(settings: { 'captain_models' => { 'assistant' => 'vendor/gone' } }) # rubocop:disable Rails/SkipsModelValidations
      stub_models(platform: platform_model)

      expect(state).not_to be_own_model
    end

    it 'counts the same model chosen on purpose as the platform one' do
      account.update_columns(settings: { 'captain_models' => { 'assistant' => platform_model } }) # rubocop:disable Rails/SkipsModelValidations
      stub_models(platform: platform_model)

      expect(state).not_to be_own_model
    end

    it 'is unknown, and does not break the card, when the AI settings of the platform cannot be read' do
      allow(Llm::Config).to receive(:model_for).and_raise(StandardError, 'no key')

      expect(state.model_id).to be_nil
      expect(state.platform_model_id).to be_nil
      expect(state).not_to be_own_model
    end

    it 'is unknown when no model can be chosen at all' do
      stub_models(platform: nil)

      expect(state.model_id).to be_nil
    end
  end

  describe 'the agents' do
    it 'counts the agents that answer clients and how many are switched on, in this account only' do
      create(:captain_assistant, account: account, active: true)
      create(:captain_assistant, account: account, active: true)
      create(:captain_assistant, account: account, active: false)
      create(:captain_assistant, account: create(:account), active: true)

      expect(state.agents_total).to eq(3)
      expect(state.agents_enabled).to eq(2)
    end

    it 'does not count the internal assistants of the operators' do
      create(:captain_assistant, account: account, active: true)
      create(:captain_assistant, account: account, usage_mode: 'internal_assistant', active: true)

      expect(state.agents_total).to eq(1)
      expect(state.agents_enabled).to eq(1)
    end

    it 'counts the agents that keep a model of their own' do
      create(:captain_assistant, account: account)
      create(:captain_assistant, account: account).tap { |agent| agent.update_columns(config: { 'model' => 'openai/gpt-5.4' }) } # rubocop:disable Rails/SkipsModelValidations
      create(:captain_assistant, account: account).tap { |agent| agent.update_columns(config: { 'model' => '' }) } # rubocop:disable Rails/SkipsModelValidations

      expect(state.agents_with_own_model).to eq(1)
    end

    it 'is zero for an account with no agent' do
      expect(state).to have_attributes(agents_total: 0, agents_enabled: 0, agents_with_own_model: 0)
    end
  end

  describe 'the key of OpenRouter' do
    it 'is not allowed and not connected by default' do
      expect(state).not_to be_own_key_allowed
      expect(state).not_to be_own_key_connected
    end

    it 'follows the flag of the account for the permission' do
      account.enable_features!('captain_openrouter_byok')

      expect(state).to be_own_key_allowed
      expect(state).not_to be_own_key_connected
    end

    it 'knows that a key is connected, whether the flag is on or not' do
      create(:integrations_hook, account: account, app_id: 'openrouter', access_token: 'account-openrouter-key', settings: {})

      expect(state).to be_own_key_connected
      expect(state).not_to be_own_key_allowed
    end

    it 'does not count a key that is switched off' do
      create(:integrations_hook, account: account, app_id: 'openrouter', access_token: 'account-openrouter-key', settings: {}, status: 'disabled')

      expect(state).not_to be_own_key_connected
    end

    it 'does not count the key of another account' do
      create(:integrations_hook, account: create(:account), app_id: 'openrouter', access_token: 'other-key', settings: {})

      expect(state).not_to be_own_key_connected
    end
  end

  describe '#module_enabled?' do
    it 'follows the function «ИИ-агенты» of the account' do
      expect(state).not_to be_module_enabled

      account.enable_features!('captain_integration')

      expect(state).to be_module_enabled
    end
  end
end
