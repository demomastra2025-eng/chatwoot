require 'rails_helper'

RSpec.describe Channels::WhatsappWeb::MessageUpdateBackfillJob do
  around do |example|
    with_modified_env(
      'EVOLUTION_API_URL' => 'https://evolution.example.com',
      'EVOLUTION_API_KEY' => 'test-api-key',
      'FRONTEND_URL' => 'https://app.example.com'
    ) do
      example.run
    end
  end

  let(:channel) { create(:channel_whatsapp_web) }
  let(:contact) { create(:contact, account: channel.account, phone_number: '+15551234567') }
  let(:contact_inbox) { create(:contact_inbox, contact: contact, inbox: channel.inbox, source_id: '15551234567') }
  let!(:conversation) do
    create(:conversation, account: channel.account, inbox: channel.inbox, contact: contact, contact_inbox: contact_inbox)
  end

  it 'runs on the whatsappweb_echo queue' do
    expect(described_class.queue_name).to eq('whatsappweb_echo')
  end

  it 'backfills a missing outbound message from the provider and applies the status' do
    expect_any_instance_of(WhatsappWeb::Providers::EvolutionService).to receive(:fetch_message_by_source_id).with(
      source_id: 'WA_BACKFILL_1',
      remote_jid: nil,
      from_me: true
    ).and_return(
      {
        key: {
          id: 'WA_BACKFILL_1',
          remoteJid: '15551234567@s.whatsapp.net',
          fromMe: true
        },
        message: {
          conversation: 'Sent from the phone'
        }
      }
    )

    described_class.perform_now(
      channel.id,
      {
        'keyId' => 'WA_BACKFILL_1',
        'remoteJid' => '219399998935287@lid',
        'fromMe' => true,
        'status' => 'READ'
      }
    )

    message = channel.inbox.messages.find_by(source_id: 'WA_BACKFILL_1')
    expect(message).to be_present
    expect(message.message_type).to eq('outgoing')
    expect(message.status).to eq('read')
  end

  it 'retries a bounded number of times when the provider record is still unavailable' do
    allow_any_instance_of(WhatsappWeb::Providers::EvolutionService).to receive(:fetch_message_by_source_id).and_return(nil)

    expect do
      described_class.perform_now(
        channel.id,
        {
          'keyId' => 'WA_BACKFILL_2',
          'remoteJid' => '219399998935287@lid',
          'fromMe' => true,
          'status' => 'DELIVERY_ACK'
        },
        1
      )
    end.to have_enqueued_job(described_class).with(
      channel.id,
      hash_including('key' => hash_including('id' => 'WA_BACKFILL_2')),
      2
    )
  end
end
