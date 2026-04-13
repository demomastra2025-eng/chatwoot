require 'rails_helper'

RSpec.describe WhatsappWeb::MarkMessagesReadService do
  let(:channel) { create(:channel_whatsapp_web) }
  let(:contact) do
    create(
      :contact,
      account: channel.account,
      additional_attributes: {
        canonical_jid: '15551234567@s.whatsapp.net'
      }
    )
  end
  let(:contact_inbox) do
    create(
      :contact_inbox,
      contact: contact,
      inbox: channel.inbox,
      source_id: '15551234567'
    )
  end
  let(:conversation) do
    create(
      :conversation,
      account: channel.account,
      inbox: channel.inbox,
      contact: contact,
      contact_inbox: contact_inbox,
      agent_last_seen_at: 2.hours.ago
    )
  end
  let!(:message) do
    create(
      :message,
      account: channel.account,
      inbox: channel.inbox,
      conversation: conversation,
      sender: contact,
      message_type: :incoming,
      source_id: 'wa-incoming-1',
      created_at: 10.minutes.ago
    )
  end

  it 'marks unread incoming messages as read through the provider' do
    provider_service = instance_double(
      WhatsappWeb::Providers::EvolutionService,
      mark_messages_read: true
    )

    allow(channel).to receive(:provider_service).and_return(provider_service)

    expect(provider_service).to receive(:mark_messages_read).with(
      messages: [
        {
          remoteJid: '15551234567@s.whatsapp.net',
          fromMe: false,
          id: 'wa-incoming-1'
        }
      ]
    )

    described_class.new(conversation: conversation).perform
  end
end
