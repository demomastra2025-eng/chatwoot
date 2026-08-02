require 'rails_helper'

RSpec.describe Telephony::AiVoice::FishVoice do
  let(:account) { create(:account) }
  let(:voice) do
    described_class.create!(
      account: account,
      provider_model_id: 'fish-reference-id',
      title: 'Private support voice',
      state: 'trained',
      visibility: 'private'
    )
  end

  it 'finds only assistants in the same account that use the Fish reference' do
    selected = create(
      :captain_assistant,
      account: account,
      config: { 'voice_settings' => { 'provider' => 'fish', 'voice' => voice.provider_model_id } }
    )
    other_voice = described_class.create!(
      account: account,
      provider_model_id: 'other',
      title: 'Other voice',
      state: 'trained',
      visibility: 'private'
    )
    create(:captain_assistant, account: account, config: { 'voice_settings' => { 'provider' => 'fish', 'voice' => other_voice.provider_model_id } })
    other_account = create(:account)
    legacy_other_assistant = create(:captain_assistant, account: other_account)
    legacy_other_assistant.update_column( # rubocop:disable Rails/SkipsModelValidations -- models a legacy cross-account reference
      :config,
      { 'voice_settings' => { 'provider' => 'fish', 'voice' => voice.provider_model_id } }
    )

    expect(voice.selected_assistants).to contain_exactly(selected)
    expect(voice.selected_assistants_count).to eq(1)
  end
end
