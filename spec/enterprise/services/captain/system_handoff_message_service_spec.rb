require 'rails_helper'

RSpec.describe Captain::SystemHandoffMessageService do
  let(:account) { create(:account, locale: 'ru') }
  let(:inbox) { create(:inbox, account: account) }
  let(:conversation) { create(:conversation, inbox: inbox, account: account, status: :open) }
  let(:assistant) { create(:captain_assistant, account: account) }

  # The handoff message is a workspace-level AI setting shared by every agent (API modes: fixed | generated).
  def configure(enabled:, mode: 'fixed', text: '', instruction: '')
    configure_notice(account, 'handoff_message', enabled: enabled, mode: mode, text: text, instruction: instruction)
  end

  it 'posts the configured static handoff message as the assistant' do
    configure(enabled: true, mode: 'fixed', text: 'Передаю администратору.')

    message = described_class.new(conversation: conversation, assistant: assistant).perform

    expect(message).to have_attributes(content: 'Передаю администратору.', message_type: 'outgoing', private: false, sender: assistant)
  end

  it 'posts the text the notice model wrote in AI mode' do
    configure(enabled: true, mode: 'generated', text: 'Configured text', instruction: 'Коротко.')
    create(:message, conversation: conversation, account: account, inbox: inbox, message_type: :incoming, content: 'Нужен администратор')
    stub_notice_model('Администратор продолжит диалог с вами.')

    message = described_class.new(conversation: conversation, assistant: assistant).perform

    expect(message).to have_attributes(content: 'Администратор продолжит диалог с вами.', sender: assistant, private: false)
  end

  it 'falls back to the configured text, then to a neutral sentence, when the notice model fails' do
    configure(enabled: true, mode: 'generated', text: 'Configured text')
    stub_notice_model(error: StandardError.new('boom'))
    expect(described_class.new(conversation: conversation, assistant: assistant).content).to eq('Configured text')

    configure(enabled: true, mode: 'generated', text: '')
    expect(described_class.new(conversation: conversation, assistant: assistant).content)
      .to eq('Сотрудник продолжит диалог с вами.')
  end

  it 'posts nothing when the handoff message is disabled or has no fixed text' do
    configure(enabled: false, text: 'Configured text')
    expect(described_class.new(conversation: conversation, assistant: assistant).perform).to be_nil

    configure(enabled: true, mode: 'fixed', text: '')
    expect(described_class.new(conversation: conversation, assistant: assistant).perform).to be_nil

    expect(conversation.messages.outgoing).to be_empty
  end

  it 'posts nothing and never calls the model while the handoff message is disabled, even in AI mode' do
    configure(enabled: false, mode: 'generated', text: 'Configured text')
    expect(Llm::Runtime).not_to receive(:chat)

    expect(described_class.new(conversation: conversation, assistant: assistant).perform).to be_nil
  end

  it 'writes the text once in #prepare, before the lock, and posts it in #perform' do
    configure(enabled: true, mode: 'generated')
    stub_notice_model('Администратор продолжит диалог с вами.')
    expect(Llm::Runtime).to receive(:chat).once.and_return(Struct.new(:content).new('Администратор продолжит диалог с вами.'))
    service = described_class.new(conversation: conversation, assistant: assistant)

    expect(service.prepare).to eq(service)
    expect(service.perform).to have_attributes(content: 'Администратор продолжит диалог с вами.')
  end

  it 'posts the fixed text, then the neutral sentence, without any model call when generate: false' do
    stub_notice_model
    configure(enabled: true, mode: 'generated', text: 'Configured text')
    posted = described_class.new(conversation: conversation, assistant: assistant, generate: false).perform
    expect(posted).to have_attributes(content: 'Configured text', sender: assistant, private: false)

    configure(enabled: true, mode: 'generated', text: '')
    expect(described_class.new(conversation: conversation, assistant: assistant, generate: false).content)
      .to eq('Сотрудник продолжит диалог с вами.')
    expect(Llm::Runtime).not_to have_received(:chat).with(hash_including(feature: :customer_notice))
  end

  it 'ignores a legacy per-agent handoff message and follows the workspace setting' do
    assistant.update!(config: assistant.config.merge('handoff_message_enabled' => true, 'handoff_message_mode' => 'static',
                                                     'handoff_message' => 'Legacy agent text'))

    expect(described_class.new(conversation: conversation, assistant: assistant).content).to be_nil
  end
end
