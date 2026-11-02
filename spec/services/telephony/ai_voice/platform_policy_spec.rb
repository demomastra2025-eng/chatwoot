require 'rails_helper'

RSpec.describe Telephony::AiVoice::PlatformPolicy do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:profile) { described_class::DEFAULTS::DEFAULTS }

  before do
    allow(Llm::Config).to receive(:model_for).with(feature: :assistant, account: account).and_return('platform/text-model')
  end

  %w[gemini-live openai-live openai-realtime elevenlabs cartesia fish].each do |provider|
    it "resolves the platform native profile for legacy #{provider} records and both tool dispatch paths" do
      saved = { 'provider' => provider, 'model' => 'retired/model', 'delegation_model' => 'retired/delegate',
                'thinking_level' => 'high', 'voice' => 'foreign-voice-id', 'language' => 'kk-KZ',
                'first_message' => 'Business greeting', 'recording_enabled' => false, 'manager_handoff_mode' => 'callback' }
      assistant.update!(config: assistant.config.merge('voice_settings' => saved))
      policy = build(:telephony_routing_policy, account: account, ai_voice_settings: saved.merge('model' => 'route/model'))
      expected = profile.slice(*described_class::RETIRED_FIELDS).merge('delegation_model' => 'platform/text-model', 'voice' => 'sulafat')

      effective = described_class.new(account: account, settings: saved).resolve
      catalog_settings = Telephony::AiVoice::ToolDispatchService.send(:normalized_voice_settings, policy, assistant, saved)
      dispatch = Telephony::AiVoice::ToolDispatchService.new(tool_name: 'request_transfer', payload: {})
      allow(dispatch).to receive_messages(captain_assistant: assistant, routing_policy: policy)
      expected.merge!('language' => 'kk-KZ', 'first_message' => 'Business greeting',
                      'recording_enabled' => false, 'manager_handoff_mode' => 'callback')
      expect([effective, catalog_settings, dispatch.send(:voice_settings)]).to all(include(expected))
      expect(assistant.reload.config['voice_settings']).to eq(saved)
    end
  end

  it 'preserves a compatible selected voice and canonicalizes its case' do
    expect(described_class.new(account: account, settings: { voice: 'Puck' }).resolve['voice']).to eq('puck')
  end

  it 'accepts canonical voice names using the same normalized form as runtime' do
    expect(described_class.write_violation({ voice: 'Puck' }, platform: true)).to be_nil
    expect(described_class.new(account: account, settings: { voice: 'Puck' }).resolve['voice']).to eq('puck')
  end

  it 'preserves explicit nil and blank resets from the existing normalizer' do
    results = [nil, '', '  '].map do |value|
      { violation: described_class.write_violation({ voice: value }, platform: true),
        voice: described_class.merge_updates({ 'voice' => 'puck' }, { 'voice' => value })['voice'] }
    end
    expect(results).to all(include(violation: nil, voice: profile['voice']))
  end

  it 'keeps metadata readable without a delegation slot, and fails only on runtime validation' do
    allow(Llm::Config).to receive(:model_for).with(feature: :assistant, account: account).and_return(nil)
    policy = described_class.new(account: account, settings: { delegation_model: 'retired/fallback' })
    expect(policy.public_settings['delegation_model']).to be_nil
    expect { policy.validate_runtime! }.to raise_error(Telephony::Error) do |error|
      expect([error.code, error.status]).to eq(['voice_delegation_unavailable', :service_unavailable])
    end
  end

  it 'projects nested archives out before normalizing scalar text' do
    settings = { first_message: { archive: 'PRIVATE_ARCHIVE' }, voice_character_prompt: { archive: 'PRIVATE_ARCHIVE' },
                 history: { prompt: 'PRIVATE_ARCHIVE' }, system_prompt: 'PRIVATE_CURRENT' }
    policy = described_class.new(account: account, settings: settings)
    expect(policy.public_settings.to_s).not_to include('PRIVATE_ARCHIVE', 'PRIVATE_CURRENT')
    expect(policy.public_settings(user: create(:super_admin)).to_s).to include('PRIVATE_CURRENT')
    expect(policy.public_settings(user: create(:super_admin)).to_s).not_to include('PRIVATE_ARCHIVE')
  end

  it 'merges only explicitly submitted business keys without normalizing saved legacy provenance' do
    legacy = { 'provider' => 'fish', 'model' => 'retired', 'unknown_archive' => { 'prompt' => 'PRIVATE' }, 'voice' => 'old-fish-id' }
    expect(described_class.merge_updates(legacy, { 'first_message' => 'New greeting', 'recording_enabled' => false })).to eq(
      legacy.merge('first_message' => 'New greeting', 'recording_enabled' => false)
    )
  end
end
