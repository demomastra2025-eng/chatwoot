require 'rails_helper'

RSpec.describe WhatsappWeb::IncomingEventService do
  around do |example|
    with_modified_env(
      'EVOLUTION_API_URL' => 'https://evolution.example.com',
      'EVOLUTION_API_KEY' => 'test-api-key',
      'FRONTEND_URL' => 'https://app.example.com'
    ) do
      example.run
    end
  end

  describe '#perform' do
    let(:channel) { create(:channel_whatsapp_web) }

    it 'updates qrcode state on qrcode.updated' do
      freeze_time do
        described_class.new(
          channel: channel,
          payload: {
            event: 'qrcode.updated',
            data: { qrcode: { base64: 'data:image/png;base64,abc', code: '123456' } }
          }.with_indifferent_access
        ).perform

        channel.reload
        expect(channel.lifecycle_state).to eq('qr_ready')
        expect(channel.connection_state).to eq('connecting')
        expect(channel.qr_code).to include('code' => '123456')
        expect(channel.last_synced_at).to be_present
        expect(channel.qr_generated_at).to be_within(1.second).of(Time.current)
      end
    end

    it 'marks the channel failed when qrcode.updated contains a provider error payload' do
      described_class.new(
        channel: channel,
        payload: {
          event: 'qrcode.updated',
          data: {
            message: 'QR code limit reached, please login again',
            statusCode: 500
          }
        }.with_indifferent_access
      ).perform

      channel.reload
      expect(channel.lifecycle_state).to eq('failed')
      expect(channel.connection_state).to eq('refused')
      expect(channel.qr_code).to eq({})
      expect(channel.qr_generated_at).to be_nil
      expect(channel.last_error).to eq('QR code limit reached, please login again | status code: 500')
    end

    it 'dispatches inbound message upserts to the message service' do
      service = instance_double(WhatsappWeb::IncomingMessageService, perform: true)

      expect(WhatsappWeb::IncomingMessageService).to receive(:new).with(
        inbox: channel.inbox,
        params: hash_including(
          key: hash_including(id: 'message-1', remoteJid: '15551234567@s.whatsapp.net', fromMe: false)
        ),
        outgoing_echo: false
      ).and_return(service)

      described_class.new(
        channel: channel,
        payload: {
          event: 'messages.upsert',
          data: {
            key: { id: 'message-1', remoteJid: '15551234567@s.whatsapp.net', fromMe: false },
            pushName: 'Alice',
            message: { conversation: 'Hello' }
          }
        }.with_indifferent_access
      ).perform
    end

    it 'enqueues self-sent message upserts as delayed outgoing echoes' do
      delayed_job = class_double(Channels::WhatsappWeb::OutgoingEchoJob, perform_later: true)

      allow(Channels::WhatsappWeb::OutgoingEchoJob).to receive(:set)
        .with(wait: 2.seconds)
        .and_return(delayed_job)
      expect(delayed_job).to receive(:perform_later).with(
        channel.id,
        hash_including(
          'key' => hash_including(
            'id' => 'message-2',
            'remoteJid' => '15551234567@s.whatsapp.net',
            'fromMe' => true
          )
        )
      )
      expect(WhatsappWeb::IncomingMessageService).not_to receive(:new)

      described_class.new(
        channel: channel,
        payload: {
          event: 'messages.upsert',
          data: {
            key: { id: 'message-2', remoteJid: '15551234567@s.whatsapp.net', fromMe: true },
            message: { conversation: 'Self sent' }
          }
        }.with_indifferent_access
      ).perform
    end

    it 'enqueues send.message events as delayed outgoing echoes' do
      delayed_job = class_double(Channels::WhatsappWeb::OutgoingEchoJob, perform_later: true)

      allow(Channels::WhatsappWeb::OutgoingEchoJob).to receive(:set)
        .with(wait: 2.seconds)
        .and_return(delayed_job)
      expect(delayed_job).to receive(:perform_later).with(
        channel.id,
        hash_including(
          'key' => hash_including(
            'id' => 'message-send-1',
            'remoteJid' => '15551234567@s.whatsapp.net',
            'fromMe' => true
          ),
          'status' => 'PENDING'
        )
      )

      described_class.new(
        channel: channel,
        payload: {
          event: 'send.message',
          data: {
            key: { id: 'message-send-1', remoteJid: '15551234567@s.whatsapp.net', fromMe: true },
            message: { conversation: 'Sent via provider webhook' },
            status: 'PENDING'
          }
        }.with_indifferent_access
      ).perform
    end

    it 'ignores group message upserts' do
      expect(WhatsappWeb::IncomingMessageService).not_to receive(:new)

      described_class.new(
        channel: channel,
        payload: {
          event: 'messages.upsert',
          data: {
            key: { id: 'message-3', remoteJid: '12345@g.us', fromMe: false },
            message: { conversation: 'Group message' }
          }
        }.with_indifferent_access
      ).perform
    end

    it 'ignores message upserts from configured ignored jids' do
      channel.update!(ignore_jids: ['15550009999@s.whatsapp.net'])
      expect(WhatsappWeb::IncomingMessageService).not_to receive(:new)

      described_class.new(
        channel: channel,
        payload: {
          event: 'messages.upsert',
          data: {
            key: { id: 'message-ignored', remoteJid: '15550009999@s.whatsapp.net', fromMe: false },
            message: { conversation: 'Ignored message' }
          }
        }.with_indifferent_access
      ).perform
    end

    it 'maps provider delivery updates onto existing messages' do
      message = create(
        :message,
        account: channel.account,
        inbox: channel.inbox,
        conversation: create(:conversation, account: channel.account, inbox: channel.inbox),
        message_type: :outgoing,
        source_id: 'outgoing-1',
        status: :sent
      )

      described_class.new(
        channel: channel,
        payload: {
          event: 'messages.update',
          data: [
            {
              key: { id: 'outgoing-1', fromMe: true },
              update: { status: 4 }
            }
          ]
        }.with_indifferent_access
      ).perform

      expect(message.reload.status).to eq('read')
    end

    it 'maps flattened provider status updates with string statuses onto existing messages' do
      message = create(
        :message,
        account: channel.account,
        inbox: channel.inbox,
        conversation: create(:conversation, account: channel.account, inbox: channel.inbox),
        message_type: :outgoing,
        source_id: 'outgoing-flat-1',
        status: :sent
      )

      described_class.new(
        channel: channel,
        payload: {
          event: 'messages.update',
          data: {
            keyId: 'outgoing-flat-1',
            remoteJid: '219399998935287@lid',
            fromMe: true,
            status: 'READ'
          }
        }.with_indifferent_access
      ).perform

      expect(message.reload.status).to eq('read')
    end

    it 'does not downgrade message status when provider events arrive out of order' do
      message = create(
        :message,
        account: channel.account,
        inbox: channel.inbox,
        conversation: create(:conversation, account: channel.account, inbox: channel.inbox),
        message_type: :outgoing,
        source_id: 'outgoing-flat-2',
        status: :delivered
      )

      described_class.new(
        channel: channel,
        payload: {
          event: 'messages.update',
          data: {
            keyId: 'outgoing-flat-2',
            remoteJid: '219399998935287@lid',
            fromMe: true,
            status: 'SERVER_ACK'
          }
        }.with_indifferent_access
      ).perform

      expect(message.reload.status).to eq('delivered')
    end

    it 'schedules a backfill when a self-sent status update arrives before the local message exists' do
      delayed_job = class_double(Channels::WhatsappWeb::MessageUpdateBackfillJob, perform_later: true)

      allow(Channels::WhatsappWeb::MessageUpdateBackfillJob).to receive(:set)
        .with(wait: 3.seconds)
        .and_return(delayed_job)
      expect(delayed_job).to receive(:perform_later).with(
        channel.id,
        hash_including(
          'key' => hash_including(
            'id' => 'outgoing-missing-1',
            'remoteJid' => '15551234567@s.whatsapp.net',
            'fromMe' => true
          ),
          'update' => hash_including('status' => 3)
        )
      )

      described_class.new(
        channel: channel,
        payload: {
          event: 'messages.update',
          data: [
            {
              key: { id: 'outgoing-missing-1', remoteJid: '15551234567@s.whatsapp.net', fromMe: true },
              update: { status: 3 }
            }
          ]
        }.with_indifferent_access
      ).perform

      expect(channel.reload.sync_state_payload['echo_status_miss_count']).to eq(1)
      expect(channel.sync_state_payload['last_echo_status_miss_source_id']).to eq('outgoing-missing-1')
    end

    it 'normalizes flattened status updates before enqueuing backfill' do
      delayed_job = class_double(Channels::WhatsappWeb::MessageUpdateBackfillJob, perform_later: true)

      allow(Channels::WhatsappWeb::MessageUpdateBackfillJob).to receive(:set)
        .with(wait: 3.seconds)
        .and_return(delayed_job)
      expect(delayed_job).to receive(:perform_later).with(
        channel.id,
        hash_including(
          'key' => hash_including(
            'id' => 'outgoing-missing-flat-1',
            'remoteJid' => '219399998935287@lid',
            'fromMe' => true
          ),
          'update' => hash_including('status' => 'DELIVERY_ACK')
        )
      )

      described_class.new(
        channel: channel,
        payload: {
          event: 'messages.update',
          data: {
            keyId: 'outgoing-missing-flat-1',
            remoteJid: '219399998935287@lid',
            fromMe: true,
            status: 'DELIVERY_ACK'
          }
        }.with_indifferent_access
      ).perform

      expect(channel.reload.sync_state_payload['echo_status_miss_count']).to eq(1)
      expect(channel.sync_state_payload['last_echo_status_miss_source_id']).to eq('outgoing-missing-flat-1')
    end

    it 'does not enqueue a history sync when the connection opens before provider history is ready' do
      expect do
        described_class.new(
          channel: channel,
          payload: {
            event: 'connection.update',
            data: {
              state: 'open'
            }
          }.with_indifferent_access
        ).perform
      end.not_to have_enqueued_job(Channels::WhatsappWeb::HistorySyncJob)
    end

    it 'keeps provider error details when the runtime moves from qr failure into refused' do
      channel.update!(last_error: 'QR code limit reached, please login again | status code: 500')

      described_class.new(
        channel: channel,
        payload: {
          event: 'connection.update',
          data: {
            state: 'refused',
            statusReason: 428
          }
        }.with_indifferent_access
      ).perform

      expect(channel.reload.last_error).to eq(
        'QR code limit reached, please login again | status code: 500 | status reason: 428'
      )
      expect(channel.connection_state).to eq('refused')
      expect(channel.lifecycle_state).to eq('failed')
    end

    it 'clears qr state when the runtime reports a terminal failure' do
      channel.update!(
        qr_code: { 'base64' => 'data:image/png;base64,abc' },
        sync_state: channel.sync_state_payload.merge('qr_generated_at' => Time.current.iso8601)
      )

      described_class.new(
        channel: channel,
        payload: {
          event: 'status.instance',
          data: {
            status: 'error',
            disconnectionReasonCode: 515
          }
        }.with_indifferent_access
      ).perform

      channel.reload
      expect(channel.lifecycle_state).to eq('failed')
      expect(channel.qr_code).to eq({})
      expect(channel.qr_generated_at).to be_nil
    end

    it 'treats messages.set as a successful connection without starting an early history sync' do
      expect(WhatsappWeb::HistoryImportService).not_to receive(:new)

      expect do
        described_class.new(
          channel: channel,
          payload: {
            event: 'messages.set',
            data: [
              {
                key: {
                  id: 'history-msg-1',
                  remoteJid: '15551234567@s.whatsapp.net',
                  fromMe: false
                },
                pushName: 'Alice',
                messageTimestamp: 1.hour.ago.to_i,
                message: {
                  conversation: 'Imported from history'
                }
              }
            ]
          }.with_indifferent_access
        ).perform
      end.not_to have_enqueued_job(Channels::WhatsappWeb::HistorySyncJob)

      channel.reload
      expect(channel.lifecycle_state).to eq('connected')
      expect(channel.connection_state).to eq('open')
      expect(channel.qr_code).to eq({})
    end

    it 'does not enqueue a sync job when imports are disabled' do
      channel.update!(import_contacts: false, import_messages: false)

      expect do
        described_class.new(
          channel: channel,
          payload: {
            event: 'messaging-history.set',
            data: {
              messageCount: 1448,
              contactCount: 1019
            }
          }.with_indifferent_access
        ).perform
      end.not_to have_enqueued_job(Channels::WhatsappWeb::HistorySyncJob)
    end

    it 'records provider history snapshots and schedules a debounced full sync while the local baseline is stale' do
      freeze_time do
        expect do
          described_class.new(
            channel: channel,
            payload: {
              event: 'messaging-history.set',
              data: {
                messageCount: 1448,
                contactCount: 1019
              }
            }.with_indifferent_access
          ).perform
        end.to have_enqueued_job(Channels::WhatsappWeb::HistorySyncJob).with(
          channel.id,
          'full',
          hash_including(
            'requested_at' => Time.current.iso8601,
            'expected_provider_history_synced_at' => Time.current.iso8601
          )
        )

        channel.reload
        expect(channel.history_synced_at).to be_nil
        expect(channel.provider_history_synced_at).to be_within(1.second).of(Time.current)
        expect(channel.evolution_state_payload['provider_history_message_count']).to eq(1448)
        expect(channel.evolution_state_payload['provider_history_contact_count']).to eq(1019)
      end
    end

    it 're-requests a full sync when a newer provider history snapshot arrives after an earlier full baseline' do
      contact = create(:contact, account: channel.account, phone_number: '+15551234567')
      contact_inbox = create(:contact_inbox, inbox: channel.inbox, contact: contact, source_id: '15551234567')
      conversation = create(
        :conversation,
        account: channel.account,
        inbox: channel.inbox,
        contact: contact,
        contact_inbox: contact_inbox
      )
      create(
        :message,
        account: channel.account,
        inbox: channel.inbox,
        conversation: conversation,
        sender: contact,
        message_type: :incoming,
        source_id: 'history-msg-baseline',
        content_attributes: { imported_history: true }
      )

      older_snapshot = 20.minutes.ago.change(usec: 0)
      channel.update!(
        sync_state: channel.sync_state_payload.merge(
          'history_synced_at' => older_snapshot.iso8601,
          'last_local_history_sync_finished_at' => older_snapshot.iso8601,
          'last_history_sync_mode' => 'full',
          'last_history_message_count' => 1,
          'last_history_contact_count' => 1,
          'provider_history_synced_at' => older_snapshot.iso8601,
          'local_history_provider_synced_at' => older_snapshot.iso8601,
          'provider_history_message_count' => 62,
          'provider_history_contact_count' => 41
        )
      )

      freeze_time do
        expect do
          described_class.new(
            channel: channel,
            payload: {
              event: 'messaging-history.set',
              data: {
                messageCount: 2657,
                contactCount: 50
              }
            }.with_indifferent_access
          ).perform
        end.to have_enqueued_job(Channels::WhatsappWeb::HistorySyncJob).with(
          channel.id,
          'full',
          hash_including(
            'requested_at' => Time.current.iso8601,
            'expected_provider_history_synced_at' => Time.current.iso8601
          )
        )

        channel.reload
        expect(channel.provider_history_synced_at).to be_within(1.second).of(Time.current)
        expect(channel.local_history_provider_synced_at).to be_within(1.second).of(older_snapshot)
        expect(channel.preferred_history_sync_mode).to eq('full')
      end
    end

    it 'does not enqueue a duplicate reconnect sync while a provider-snapshot catchup is already pending' do
      channel.update!(
        sync_state: channel.sync_state_payload.merge(
          'history_synced_at' => 1.hour.ago.iso8601,
          'last_local_history_sync_finished_at' => 1.hour.ago.iso8601,
          'last_history_sync_mode' => 'full',
          'last_history_message_count' => 10,
          'last_history_contact_count' => 1
        )
      )
      create(:contact_inbox, inbox: channel.inbox, source_id: '15551234567')
      conversation = create(
        :conversation,
        account: channel.account,
        inbox: channel.inbox,
        contact: channel.inbox.contact_inboxes.first.contact,
        contact_inbox: channel.inbox.contact_inboxes.first
      )
      create(
        :message,
        account: channel.account,
        inbox: channel.inbox,
        conversation: conversation,
        sender: channel.inbox.contact_inboxes.first.contact,
        message_type: :incoming,
        source_id: 'history-msg-baseline',
        content_attributes: { imported_history: true }
      )

      described_class.new(
        channel: channel,
        payload: {
          event: 'messaging-history.set',
          data: {
            messageCount: 1448,
            contactCount: 1019
          }
        }.with_indifferent_access
      ).perform

      clear_enqueued_jobs

      expect do
        described_class.new(
          channel: channel,
          payload: {
            event: 'connection.update',
            data: {
              state: 'open'
            }
          }.with_indifferent_access
        ).perform
      end.not_to have_enqueued_job(Channels::WhatsappWeb::HistorySyncJob)
    end

    it 'falls back to a full sync when the provider snapshot exists but the local inbox is still empty' do
      channel.update!(
        sync_state: channel.sync_state_payload.merge(
          'history_synced_at' => 1.hour.ago.iso8601,
          'provider_history_synced_at' => Time.current.iso8601,
          'provider_history_message_count' => 1448,
          'provider_history_contact_count' => 1019
        )
      )

      expect do
        described_class.new(
          channel: channel,
          payload: {
            event: 'connection.update',
            data: {
              state: 'open'
            }
          }.with_indifferent_access
        ).perform
      end.to have_enqueued_job(Channels::WhatsappWeb::HistorySyncJob).with(
        channel.id,
        'full',
        hash_including('expected_provider_history_synced_at' => kind_of(String))
      )
    end

    it 'syncs labels from Evolution events' do
      contact_inbox = create(:contact_inbox, inbox: channel.inbox, source_id: '15551234567')
      conversation = create(
        :conversation,
        account: channel.account,
        inbox: channel.inbox,
        contact: contact_inbox.contact,
        contact_inbox: contact_inbox
      )

      described_class.new(
        channel: channel,
        payload: {
          event: 'labels.edit',
          data: {
            id: 'label-1',
            name: 'VIP Client',
            color: '#ff0000'
          }
        }.with_indifferent_access
      ).perform

      described_class.new(
        channel: channel,
        payload: {
          event: 'labels.association',
          data: {
            type: 'add',
            chatId: '15551234567@s.whatsapp.net',
            labelId: 'label-1'
          }
        }.with_indifferent_access
      ).perform

      expect(conversation.reload.label_list).to include('wa_vip_client')
    end

    it 'skips label associations when label sync is disabled' do
      channel.update!(sync_labels: false)
      contact_inbox = create(:contact_inbox, inbox: channel.inbox, source_id: '15551234567')
      conversation = create(
        :conversation,
        account: channel.account,
        inbox: channel.inbox,
        contact: contact_inbox.contact,
        contact_inbox: contact_inbox
      )

      channel.update_label_map!('label-1' => { 'title' => 'wa_vip_client' })

      described_class.new(
        channel: channel,
        payload: {
          event: 'labels.association',
          data: {
            type: 'add',
            chatId: '15551234567@s.whatsapp.net',
            labelId: 'label-1'
          }
        }.with_indifferent_access
      ).perform

      expect(conversation.reload.label_list).to be_empty
    end
  end
end
