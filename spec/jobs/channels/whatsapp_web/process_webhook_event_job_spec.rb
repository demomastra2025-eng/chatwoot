require 'rails_helper'

RSpec.describe Channels::WhatsappWeb::ProcessWebhookEventJob do
  around do |example|
    with_modified_env(
      'EVOLUTION_API_URL' => 'https://evolution.example.com',
      'EVOLUTION_API_KEY' => 'test-api-key',
      'FRONTEND_URL' => 'https://app.example.com'
    ) do
      example.run
    end
  end

  it 'delegates webhook payloads to the incoming event service' do
    channel = create(:channel_whatsapp_web)
    service = instance_double(WhatsappWeb::IncomingEventService, perform: true)

    expect(WhatsappWeb::IncomingEventService).to receive(:new).with(
      channel: channel,
      payload: hash_including(event: 'connection.update', data: hash_including(state: 'open'))
    ).and_return(service)
    expect(service).to receive(:perform)

    described_class.perform_now(channel.id, { 'event' => 'connection.update', 'data' => { 'state' => 'open' } })
  end

  it 'serializes message events by channel and remote jid' do
    channel = create(:channel_whatsapp_web)
    service = instance_double(WhatsappWeb::IncomingEventService, perform: true)
    job = described_class.new

    allow(WhatsappWeb::IncomingEventService).to receive(:new).and_return(service)
    allow(job).to receive(:with_lock).and_yield

    job.perform(
      channel.id,
      {
        'event' => 'messages.upsert',
        'data' => {
          'key' => {
            'id' => 'message-1',
            'remoteJid' => '15551234567@s.whatsapp.net',
            'fromMe' => false
          },
          'message' => { 'conversation' => 'Hello' }
        }
      }
    )

    expect(job).to have_received(:with_lock).with(
      format(
        Redis::Alfred::WHATSAPP_WEB_EVENT_MUTEX,
        channel_id: channel.id,
        remote_jid: '15551234567@s.whatsapp.net'
      ),
      described_class::LOCK_TIMEOUT
    )
    expect(service).to have_received(:perform)
  end

  it 'ignores webhook jobs for inboxes pending deletion' do
    channel = create(:channel_whatsapp_web)
    channel.inbox.mark_pending_deletion!

    expect(WhatsappWeb::IncomingEventService).not_to receive(:new)

    described_class.perform_now(channel.id, { 'event' => 'connection.update', 'data' => { 'state' => 'open' } })
  end
end
