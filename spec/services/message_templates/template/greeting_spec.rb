require 'rails_helper'

describe MessageTemplates::Template::Greeting do
  context 'when this hook is called' do
    let(:conversation) { create(:conversation) }

    it 'does not create an unconfigured greeting' do
      described_class.new(conversation: conversation).perform
      expect(conversation.messages.count).to eq(0)
    end

    it 'creates the greeting messages with template variable' do
      conversation.inbox.account.update!(workspace_greeting: { enabled: true, message: 'Hey, {{contact.name}} welcome to our board.',
                                                               excluded_inbox_ids: [] })
      described_class.new(conversation: conversation).perform
      expect(conversation.messages.count).to eq(1)
      expect(conversation.messages.last.content).to eq("Hey, #{conversation.contact.name} welcome to our board.")
    end

    it 'creates the greeting messages with more than one variable strings' do
      conversation.inbox.account.update!(workspace_greeting: {
                                           enabled: true,
                                           message: 'Hey, {{contact.name}} welcome to our board. - from {{account.name}}',
                                           excluded_inbox_ids: []
                                         })
      described_class.new(conversation: conversation).perform
      expect(conversation.messages.count).to eq(1)
      expect(conversation.messages.last.content).to eq("Hey, #{conversation.contact.name} welcome to our board. - from #{conversation.account.name}")
    end

    it 'creates the greeting messages' do
      conversation.inbox.account.update!(workspace_greeting: { enabled: true, message: 'Hello welcome to our board.', excluded_inbox_ids: [] })
      described_class.new(conversation: conversation).perform
      expect(conversation.messages.count).to eq(1)
      expect(conversation.messages.last.content).to eq('Hello welcome to our board.')
    end
  end
end
