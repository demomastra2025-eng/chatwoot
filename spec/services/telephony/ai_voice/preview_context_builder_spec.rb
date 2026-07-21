require 'rails_helper'

RSpec.describe Telephony::AiVoice::PreviewContextBuilder do
  subject(:context) { described_class.new(assistant: assistant).perform }

  let(:account) { create(:account) }
  let(:assistant) do
    create(
      :captain_assistant,
      account: account,
      config: {
        'voice_settings' => {
          'provider' => 'cartesia',
          'model' => 'openai/gpt-5.4-mini',
          'voice' => '71a7ad14-091c-4e8e-a314-022ece01c121',
          'language' => 'ru-KZ',
          'max_duration_sec' => 900,
          'recording_enabled' => true,
          'voice_character_prompt' => 'Говори спокойно.'
        }
      }
    )
  end
  let(:preview_service) do
    instance_double(
      Captain::Assistant::PromptPreviewService,
      preview: { assistant: { compiled_prompt: 'Compiled Captain prompt' } }
    )
  end

  before do
    allow(Captain::Assistant::PromptPreviewService).to receive(:new).with(assistant: assistant).and_return(preview_service)
  end

  it 'builds a side-effect-free, duration-limited Pipecat context' do
    expect { context }.not_to change(Telephony::CallSession, :count)

    expect(context[:account_id]).to eq(account.id)
    expect(context[:call_ref]).to match(/\Apreview:#{assistant.id}:[0-9a-f-]{36}\z/)
    expect(context[:ai]).to include(
      'provider' => 'cartesia',
      'model' => 'openai/gpt-5.4-mini',
      'max_duration_sec' => 120
    )
    expect(context[:ai]).not_to have_key('recording_enabled')
    expect(context[:ai]['system_prompt']).to include('Compiled Captain prompt', 'Говори спокойно.', 'Voice Response Contract')
    expect(context[:recording]).to eq(enabled: false, source: 'preview')
    expect(context[:tools]).to eq([])
  end
end
