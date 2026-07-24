require 'rails_helper'

RSpec.describe WhatsappTypingListener do
  subject(:listener) { described_class.instance }

  let(:account) { create(:account) }
  let(:channel) do
    create(:channel_whatsapp, account: account, provider: 'whatsapp_cloud', validate_provider_config: false, sync_templates: false)
  end
  let(:conversation) { create(:conversation, account: account, inbox: channel.inbox) }
  let(:user) { create(:user, account: account) }
  let(:provider_service) { instance_double(Whatsapp::Providers::WhatsappCloudService) }

  before do
    allow(channel).to receive(:provider_service).and_return(provider_service)
  end

  describe '#conversation_typing_on' do
    it 'sends a typing indicator for the latest incoming provider message' do
      create(:message, account: account, inbox: channel.inbox, conversation: conversation, message_type: 'incoming',
                       source_id: 'wamid.older', created_at: 2.minutes.ago)
      create(:message, account: account, inbox: channel.inbox, conversation: conversation, message_type: 'outgoing',
                       source_id: 'wamid.outgoing', created_at: 1.minute.ago)
      create(:message, account: account, inbox: channel.inbox, conversation: conversation, message_type: 'incoming',
                       source_id: 'wamid.latest', created_at: Time.current)

      expect(provider_service).to receive(:send_typing_indicator).with('wamid.latest').once

      listener.conversation_typing_on(typing_event)
    end

    it 'skips private typing events' do
      create(:message, account: account, inbox: channel.inbox, conversation: conversation, message_type: 'incoming', source_id: 'wamid.latest')
      expect(provider_service).not_to receive(:send_typing_indicator)

      listener.conversation_typing_on(typing_event(is_private: true))
    end

    it 'skips conversations without an incoming provider id' do
      create(:message, account: account, inbox: channel.inbox, conversation: conversation, message_type: 'incoming', source_id: nil)
      expect(provider_service).not_to receive(:send_typing_indicator)

      listener.conversation_typing_on(typing_event)
    end

    it 'isolates provider errors from the shared event dispatcher' do
      create(:message, account: account, inbox: channel.inbox, conversation: conversation, message_type: 'incoming', source_id: 'wamid.latest')
      allow(provider_service).to receive(:send_typing_indicator).and_raise(Timeout::Error, 'timeout')
      allow(Rails.logger).to receive(:warn)

      expect { listener.conversation_typing_on(typing_event) }.not_to raise_error
      expect(Rails.logger).to have_received(:warn).with(/typing indicator skipped/)
    end
  end

  def typing_event(is_private: false)
    Events::Base.new(
      :'conversation.typing_on',
      Time.current,
      conversation: conversation,
      user: user,
      is_private: is_private
    )
  end
end
