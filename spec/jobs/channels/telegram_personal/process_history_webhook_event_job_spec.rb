require 'rails_helper'

RSpec.describe Channels::TelegramPersonal::ProcessHistoryWebhookEventJob do
  it 'runs on the telegram_personal_history queue' do
    expect(described_class.queue_name).to eq('telegram_personal_history')
  end

  it 'delegates imported payloads to the incoming event service' do
    channel = create(:channel_telegram_personal)
    payload = {
      'event' => 'message.imported',
      'telegram_personal' => {
        'data' => {
          'message_id' => '42',
          'imported_history' => true
        }
      }
    }
    service = instance_double(TelegramPersonal::IncomingEventService, perform: true)

    allow(TelegramPersonal::IncomingEventService).to receive(:new).and_return(service)

    described_class.perform_now(channel.id, payload)

    expect(TelegramPersonal::IncomingEventService).to have_received(:new).with(
      channel: channel,
      payload: {
        event: 'message.imported',
        telegram_personal: {
          data: {
            message_id: '42',
            imported_history: true
          }
        }
      }
    )
    expect(service).to have_received(:perform)
  end

  it 'suppresses runtime events while importing history payloads' do
    channel = create(:channel_telegram_personal)
    observed_flag = nil
    service = instance_double(TelegramPersonal::IncomingEventService)

    allow(TelegramPersonal::IncomingEventService).to receive(:new).and_return(service)
    allow(service).to receive(:perform) do
      observed_flag = Current.suppress_runtime_events
    end

    described_class.perform_now(channel.id, {
                                  'event' => 'contact.imported',
                                  'telegram_personal' => { 'data' => { 'peer_user_id' => '42' } }
                                })

    expect(observed_flag).to eq(true)
    expect(Current.suppress_runtime_events).to be_nil
  end
end
