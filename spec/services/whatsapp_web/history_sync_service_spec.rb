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

  it 'imports contacts and unbounded messages despite disabled legacy settings' do
    channel = create(:channel_whatsapp_web, import_contacts: false, import_messages: false, history_lookback_days: 7)
    provider_service = instance_double(WhatsappWeb::Providers::EvolutionService)

    allow(channel).to receive(:provider_service).and_return(provider_service)
    allow(provider_service).to receive(:fetch_contacts).with(page: 1, offset: 100).and_return([])
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
    expect(provider_service).to have_received(:fetch_contacts).with(page: 1, offset: 100)
    expect(provider_service).to have_received(:fetch_chats).with(page: 1, offset: 100)
    expect(provider_service).to have_received(:fetch_messages).with(page: 1, offset: 100, from: nil)
  end

  it 'creates personal conversations from provider chat snapshots even when history messages are not importable' do
    channel = create(:channel_whatsapp_web, import_contacts: false, history_lookback_days: 0)
    provider_service = instance_double(WhatsappWeb::Providers::EvolutionService)

    allow(channel).to receive(:provider_service).and_return(provider_service)
    allow(provider_service).to receive(:fetch_contacts).with(page: 1, offset: 100).and_return([])
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

  it 'does not resend a recent failed LID message when historical contacts resolve its number' do
    channel = create(:channel_whatsapp_web)
    contact_inbox = WhatsappWeb::ContactSyncService.new(channel: channel, contact_payload: { remoteJid: '143907392331785@lid' }).perform
    conversation = create(:conversation, account: channel.account, inbox: channel.inbox,
                                         contact: contact_inbox.contact, contact_inbox: contact_inbox)
    failed = create(:message, account: channel.account, inbox: channel.inbox, conversation: conversation,
                              message_type: :outgoing, status: :failed, content_attributes: {
                                external_error: "WhatsApp Web recipient is still a provisional @lid identity for conversation #{conversation.id}"
                              })
    provider = instance_double(WhatsappWeb::Providers::EvolutionService)
    allow(channel).to receive(:provider_service).and_return(provider)
    allow(provider).to receive(:fetch_contacts).and_return([{ remoteJid: '15551234567@s.whatsapp.net', remoteLid: '143907392331785@lid' }])
    allow(provider).to receive(:fetch_chats).and_return([])
    allow(provider).to receive(:fetch_messages).and_return('messages' => { 'pages' => 1, 'records' => [] })
    clear_enqueued_jobs

    expect { described_class.new(channel: channel, mode: 'full').perform }.not_to have_enqueued_job(SendReplyJob)
    expect(enqueued_jobs.map { |job| job[:job] }).not_to include(EventDispatcherJob, AutoAssignment::AssignmentJob)
    expect(failed.reload.status).to eq('failed')
    expect(failed.content_attributes['whatsapp_web_provisional_lid_retry_attempted_at']).to be_nil
  end

  it 'restores the previous runtime suppression state if a provider fetch fails' do
    channel = create(:channel_whatsapp_web)
    provider = instance_double(WhatsappWeb::Providers::EvolutionService)
    allow(channel).to receive(:provider_service).and_return(provider)
    allow(provider).to receive(:fetch_contacts).and_raise(StandardError, 'Synthetic provider failure')
    Current.suppress_runtime_events = false
    expect { described_class.new(channel: channel, mode: 'full').perform }.to raise_error(StandardError, 'Synthetic provider failure')
    expect(Current.suppress_runtime_events).to be(false)
    Current.with_runtime_events_suppressed do
      expect { described_class.new(channel: channel, mode: 'full').perform }.to raise_error(StandardError)
      expect(Current.suppress_runtime_events).to be(true)
    end
  end
end
