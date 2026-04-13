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

  it 'ignores webhook jobs for inboxes pending deletion' do
    channel = create(:channel_whatsapp_web)
    channel.inbox.mark_pending_deletion!

    expect(WhatsappWeb::IncomingEventService).not_to receive(:new)

    described_class.perform_now(channel.id, { 'event' => 'connection.update', 'data' => { 'state' => 'open' } })
  end
end
