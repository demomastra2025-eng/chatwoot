require 'rails_helper'

RSpec.describe Captain::Assistant do
  it 'builds the runtime agent with the platform model and ignores saved per-agent parameters' do
    assistant = create(:captain_assistant)
    assistant.update_column(:config, { 'model' => 'retired/model', 'temperature' => 1, 'thinking_effort' => 'high' }) # rubocop:disable Rails/SkipsModelValidations
    allow(Llm::Config).to receive(:model_for).with(feature: :assistant, account: assistant.account)
                                             .and_return('platform/current-model')
    allow(Captain::Runtime::Agent).to receive(:new).and_call_original

    assistant.agent

    expect(Captain::Runtime::Agent).to have_received(:new).with(hash_including(model: 'platform/current-model', temperature: nil))
    runner = Captain::Assistant::AgentRunnerService.new(assistant: assistant)
    expect(runner.send(:runtime_preferences_for_run)['assistant_thinking_effort']).not_to eq('high')
    expect(assistant.reload.config).to include('model' => 'retired/model', 'temperature' => 1, 'thinking_effort' => 'high')
  end

  it 'ignores stored account model choices even with account provider credentials' do
    account = create(:account)
    account.enable_features!('captain_openrouter_byok')
    create(:integrations_hook, account: account, app_id: 'openrouter', access_token: 'test-key', settings: {})
    allow(account).to receive(:captain_models).and_return(
      'assistant' => 'account/override', 'editor' => 'account/override', 'copilot' => 'account/override'
    )
    upsert_installation_config('CAPTAIN_DEFAULT_MODEL', 'openai/gpt-6-luna')

    %w[assistant editor copilot].each do |feature|
      expect(Llm::Config.model_for(feature: feature, account: account)).to eq('openai/gpt-6-luna')
      expect(Llm::Config.installation_managed_model_feature?(feature)).to be(true)
    end
  end
end
