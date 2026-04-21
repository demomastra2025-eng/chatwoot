require 'rails_helper'

RSpec.describe WhatsappWeb::HistorySyncService do
  around do |example|
    with_modified_env(
      'EVOLUTION_API_URL' => 'https://evolution.example.com',
      'EVOLUTION_API_KEY' => 'test-api-key',
      'FRONTEND_URL' => 'https://app.example.com'
    ) do
      example.run
    end
  end

  it 'requests full history without a lookback filter when the channel is unlimited' do
    channel = create(:channel_whatsapp_web, import_contacts: false, history_lookback_days: 0)
    provider_service = instance_double(WhatsappWeb::Providers::EvolutionService)

    allow(channel).to receive(:provider_service).and_return(provider_service)
    allow(provider_service).to receive(:fetch_chats).with(page: 1, offset: 100).and_return([])
    allow(provider_service).to receive(:fetch_messages).with(page: 1, offset: 100, from: nil).and_return(
      {
        'messages' => {
          'pages' => 1,
          'records' => []
        }
      }
    )

    result = described_class.new(channel: channel, mode: 'full').perform

    expect(result).to eq(messages_imported: 0, contacts_touched: 0)
    expect(provider_service).to have_received(:fetch_chats).with(page: 1, offset: 100)
    expect(provider_service).to have_received(:fetch_messages).with(page: 1, offset: 100, from: nil)
  end

  it 'creates personal conversations from provider chat snapshots even when history messages are not importable' do
    channel = create(:channel_whatsapp_web, import_contacts: false, history_lookback_days: 0)
    provider_service = instance_double(WhatsappWeb::Providers::EvolutionService)

    allow(channel).to receive(:provider_service).and_return(provider_service)
    allow(provider_service).to receive(:fetch_chats).with(page: 1, offset: 100).and_return(
      [
        {
          remoteJid: '15551234567@s.whatsapp.net',
          pushName: 'Alice',
          updatedAt: 2.days.ago.iso8601
        },
        {
          remoteJid: '120363408125922466@g.us',
          pushName: 'Ignored group',
          updatedAt: 2.days.ago.iso8601
        }
      ]
    )
    allow(provider_service).to receive(:fetch_messages).with(page: 1, offset: 100, from: nil).and_return(
      {
        'messages' => {
          'pages' => 1,
          'records' => []
        }
      }
    )

    result = described_class.new(channel: channel, mode: 'full').perform

    expect(result).to eq(messages_imported: 0, contacts_touched: 1)
    expect(channel.inbox.conversations.count).to eq(1)
    expect(channel.inbox.conversations.first.contact_inbox.source_id).to eq('15551234567')
    expect(channel.inbox.conversations.first.contact.reload.name).to eq('+15551234567')
  end
end
