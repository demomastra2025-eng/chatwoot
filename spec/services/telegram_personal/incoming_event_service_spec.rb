require 'rails_helper'

RSpec.describe TelegramPersonal::IncomingEventService do
  describe '#perform' do
    let(:channel) do
      create(
        :channel_telegram_personal,
        runtime_state: {
          'qr_login_url' => 'tg://login?token=stale',
          'qr_login_state' => 'waiting_for_scan'
        }
      )
    end

    let(:payload) do
      {
        event: 'runtime.updated',
        telegram_personal: {
          data: {
            connection_state: 'connected',
            lifecycle_state: 'connected',
            string_session: 'fresh-session',
            runtime_state: {
              'history_sync_state' => 'running'
            }
          }
        }
      }
    end

    it 'replaces runtime_state with the gateway snapshot' do
      described_class.new(channel: channel, payload: payload).perform

      channel.reload

      expect(channel.connection_state).to eq('connected')
      expect(channel.lifecycle_state).to eq('connected')
      expect(channel.string_session).to eq('fresh-session')
      expect(channel.runtime_state['history_sync_state']).to eq('running')
      expect(channel.runtime_state).to have_key('history_sync_checkpoint')
      expect(channel.runtime_state.dig('history_sync_checkpoint', 'dialog_user_ids')).to eq([])
    end

    it 'dispatches imported history events through the incoming message service' do
      service = instance_double(TelegramPersonal::IncomingMessageService, perform: true)
      history_payload = {
        event: 'message.imported',
        telegram_personal: {
          data: {
            message_id: '123',
            text: 'history hello',
            imported_history: true
          }
        }
      }

      allow(TelegramPersonal::IncomingMessageService).to receive(:new).and_return(service)

      described_class.new(channel: channel, payload: history_payload).perform

      expect(TelegramPersonal::IncomingMessageService).to have_received(:new).with(
        inbox: channel.inbox,
        params: {
          message_id: '123',
          text: 'history hello',
          imported_history: true
        }
      )
      expect(service).to have_received(:perform)
    end

    it 'dispatches imported contacts through the contact sync service' do
      service = instance_double(TelegramPersonal::ContactSyncService, perform: true)
      contact_payload = {
        event: 'contact.imported',
        telegram_personal: {
          data: {
            peer_user_id: '23',
            username: 'sojan'
          }
        }
      }

      allow(TelegramPersonal::ContactSyncService).to receive(:new).and_return(service)

      described_class.new(channel: channel, payload: contact_payload).perform

      expect(TelegramPersonal::ContactSyncService).to have_received(:new).with(
        inbox: channel.inbox,
        params: {
          peer_user_id: '23',
          username: 'sojan'
        }
      )
      expect(service).to have_received(:perform)
    end
  end
end
