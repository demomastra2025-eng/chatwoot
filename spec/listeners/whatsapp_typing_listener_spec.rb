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

    it 'filters provider credentials from typing indicator errors' do
      secret = 'whatsapp-secret-token'
      credentials = "access_token=#{secret} {\"api_key\":\"json-secret\"} " \
                    'webhook_verify_token:labeled-secret Bearer provider-bearer-secret '
      padding = 'x' * (495 - credentials.length)
      channel.update!(provider_config: channel.provider_config.merge('api_key' => secret))
      create(:message, account: account, inbox: channel.inbox, conversation: conversation, message_type: 'incoming', source_id: 'wamid.latest')
      allow(provider_service).to receive(:send_typing_indicator).and_raise(
        StandardError,
        "#{credentials}#{padding}#{secret}"
      )
      allow(Rails.logger).to receive(:warn)

      listener.conversation_typing_on(typing_event)

      expect(Rails.logger).to have_received(:warn) do |message|
        expect(message).to include(
          'access_token=[FILTERED]',
          '{"api_key":"[FILTERED]"}',
          'webhook_verify_token:[FILTERED]',
          'Bearer [FILTERED]'
        )
        expect(message).not_to match(/whatsapp-secret|json-secret|labeled-secret|provider-bearer-secret/)
      end
    end

    it 'fails closed when the channel cannot be resolved while handling an error' do
      allow(conversation).to receive(:inbox).and_raise('association unavailable access_token=raw-secret')
      allow(Rails.logger).to receive(:warn)

      expect { listener.conversation_typing_on(typing_event) }.not_to raise_error
      expect(Rails.logger).to have_received(:warn).with(/error=RuntimeError: details unavailable/)
      expect(Rails.logger).not_to have_received(:warn).with(/raw-secret/)
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
