require 'rails_helper'

RSpec.describe Captain::SystemHandoffMessageService do
  let(:account) { create(:account, locale: 'ru') }
  let(:inbox) { create(:inbox, account: account) }
  let(:conversation) { create(:conversation, inbox: inbox, account: account, status: :open) }
  let(:assistant) { create(:captain_assistant, account: account) }

  # The handoff message is a workspace-level AI setting shared by every agent (API modes: fixed | generated).
  def configure(enabled:, mode: 'fixed', text: '')
    Captain::AccountSettings.new(account).update!(
      'handoff' => { 'handoff_message' => { 'enabled' => enabled, 'mode' => mode, 'text' => text } }
    )
  end

  it 'posts the configured static handoff message as the assistant' do
    configure(enabled: true, mode: 'fixed', text: 'Передаю администратору.')

    message = described_class.new(conversation: conversation, assistant: assistant, generated_message: 'Ignored').perform

    expect(message).to have_attributes(content: 'Передаю администратору.', message_type: 'outgoing', private: false, sender: assistant)
  end

  it 'prefers a generated text in AI mode and falls back to the configured text' do
    configure(enabled: true, mode: 'generated', text: 'Configured text')

    expect(described_class.new(conversation: conversation, assistant: assistant, generated_message: 'Generated text').content)
      .to eq('Generated text')
    expect(described_class.new(conversation: conversation, assistant: assistant, generated_message: ' ').content)
      .to eq('Configured text')
  end

  it 'posts nothing when the handoff message is disabled or not configured' do
    configure(enabled: false, text: 'Configured text')
    expect(described_class.new(conversation: conversation, assistant: assistant).perform).to be_nil

    configure(enabled: true, mode: 'fixed', text: '')
    expect(described_class.new(conversation: conversation, assistant: assistant).perform).to be_nil

    expect(conversation.messages.outgoing).to be_empty
  end

  it 'never falls back to the built-in transfer wording' do
    configure(enabled: true, mode: 'generated', text: '')

    expect(described_class.new(conversation: conversation, assistant: assistant).content).to be_nil
  end

  it 'ignores a legacy per-agent handoff message and follows the workspace setting' do
    assistant.update!(config: assistant.config.merge('handoff_message_enabled' => true, 'handoff_message_mode' => 'static',
                                                     'handoff_message' => 'Legacy agent text'))

    expect(described_class.new(conversation: conversation, assistant: assistant).content).to be_nil
  end
end
