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

    # Telegram writes the login codes from its own service account (777000): they never reach the inbox
    describe 'the chat of a Telegram service account' do
      def message_payload(event, peer_id, **data)
        {
          event: event,
          telegram_personal: {
            data: { message_id: '501', chat_id: peer_id, peer_user_id: peer_id, sender_id: peer_id, chat_type: 'private',
                    first_name: 'Telegram', text: 'Login code: 51234. Do not give this code to anyone' }.merge(data)
          }
        }
      end

      it 'skips a live login code without a message, a contact or its text in the log' do
        allow(Rails.logger).to receive(:info)

        expect { described_class.new(channel: channel, payload: message_payload('message.created', '777000')).perform }
          .not_to(change { [channel.inbox.messages.count, channel.inbox.contact_inboxes.count] })

        expect(Rails.logger).to have_received(:info).with(a_string_including('Skipped message.created of a Telegram service account'))
        expect(Rails.logger).not_to have_received(:info).with(a_string_including('51234'))
        expect(channel.reload.last_synced_at).to be_present
      end

      it 'skips the imported history and the imported contact of the service account' do
        history = message_payload('message.imported', 777_000, imported_history: true, message_created_at: 1.day.ago.iso8601)
        contact = { event: 'contact.imported', telegram_personal: { data: { peer_user_id: '777000', first_name: 'Telegram' } } }

        described_class.new(channel: channel, payload: history).perform
        described_class.new(channel: channel, payload: contact).perform

        expect(channel.inbox.messages.count).to eq(0)
        expect(channel.inbox.contact_inboxes.count).to eq(0)
      end

      # 42777 is the service account of the test servers only: on the production servers it can be a person
      it 'takes in a private chat with 42777 unless the gateway signs in to the test servers' do
        described_class.new(channel: channel, payload: message_payload('message.created', '42777', text: 'Hello')).perform

        expect(channel.inbox.contact_inboxes.pluck(:source_id)).to eq(['42777'])
        expect(channel.inbox.messages.count).to eq(1)

        with_modified_env(TELEGRAM_PERSONAL_TEST_SERVERS: 'true') do
          described_class.new(channel: channel, payload: message_payload('message.created', '42777', message_id: '503')).perform
        end

        expect(channel.inbox.messages.count).to eq(1)
      end

      # The skip and the importer decide the same way (TelegramPersonal::ChatType): without a chat type, is_group makes a group
      it 'takes a group without a chat type for a group, never for the private chat of the service account' do
        group_post = message_payload('message.created', '-100700', chat_type: nil, is_group: true, peer_user_id: '777000',
                                                                   sender_id: '777000', chat_title: 'Clinic news')

        described_class.new(channel: channel, payload: group_post).perform
        expect(channel.inbox.messages.count).to eq(0)

        channel.update!(runtime_state: channel.runtime_state_payload.merge('sync_groups' => true))
        described_class.new(channel: channel, payload: group_post).perform

        expect(channel.inbox.messages.count).to eq(1)
        expect(channel.inbox.contact_inboxes.pluck(:source_id)).to eq(['-100700'])
      end

      it 'keeps the chat of a person with the same text and a group post forwarded by the service account' do
        channel.update!(runtime_state: channel.runtime_state_payload.merge('sync_groups' => true))
        group_post = message_payload(
          'message.created', '-100500',
          message_id: '502', chat_type: 'supergroup', chat_title: 'Clinic news', peer_user_id: nil, sender_id: '777000'
        )

        described_class.new(channel: channel, payload: message_payload('message.created', '1777000')).perform
        described_class.new(channel: channel, payload: group_post).perform

        expect(channel.inbox.messages.count).to eq(2)
        expect(channel.inbox.contact_inboxes.pluck(:source_id)).to contain_exactly('1777000', '-100500')
      end
    end
  end
end
