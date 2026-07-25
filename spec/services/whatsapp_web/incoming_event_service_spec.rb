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

  after do
    Redis::Alfred.scan_each(match: 'WHATSAPP_WEB_PENDING_MESSAGE_STATUS::*') do |key|
      Redis::Alfred.delete(key)
    end
  end

  describe '#perform' do
    let(:channel) { create(:channel_whatsapp_web) }

    it 'ignores provider events while the inbox is deleting' do
      channel.inbox.mark_pending_deletion!

      described_class.new(
        channel: channel,
        payload: {
          event: 'qrcode.updated',
          data: { qrcode: { base64: 'data:image/png;base64,abc', code: '123456' } }
        }.with_indifferent_access
      ).perform

      channel.reload
      expect(channel.lifecycle_state).to eq('deleting')
      expect(channel.qr_code).to eq({})
    end

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

    it 'routes call events into the whatsapp web call service' do
      service = instance_double(WhatsappWeb::CallEventService, perform: true)

      expect(WhatsappWeb::CallEventService).to receive(:new).with(
        channel: channel,
        payload: hash_including(
          id: 'call-1',
          from: '15551234567@s.whatsapp.net',
          status: 'offer'
        )
      ).and_return(service)
      expect(service).to receive(:perform)

      described_class.new(
        channel: channel,
        payload: {
          event: 'call',
          data: {
            id: 'call-1',
            from: '15551234567@s.whatsapp.net',
            status: 'offer'
          }
        }.with_indifferent_access
      ).perform
    end

    it 'updates edited messages and marks them as edited' do
      conversation = create(:conversation, account: channel.account, inbox: channel.inbox)
      message = create(
        :message,
        account: channel.account,
        inbox: channel.inbox,
        conversation: conversation,
        message_type: :outgoing,
        content: 'Original text',
        source_id: 'wa-edited-1'
      )

      described_class.new(
        channel: channel,
        payload: {
          event: 'messages.edited',
          data: {
            key: { id: 'wa-edited-1', remoteJid: '15551234567@s.whatsapp.net', fromMe: true },
            editedMessage: {
              conversation: 'Edited on device'
            }
          }
        }.with_indifferent_access
      ).perform

      expect(message.reload.content).to eq('Edited on device')
      expect(message.content_attributes['edited']).to eq(true)
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

    it 'updates the conversation read state when an incoming message is read on the phone' do
      initial_last_seen = 2.hours.ago.change(usec: 0)
      conversation = create(
        :conversation,
        account: channel.account,
        inbox: channel.inbox,
        agent_last_seen_at: initial_last_seen,
        assignee_last_seen_at: initial_last_seen
      )
      message = create(
        :message,
        account: channel.account,
        inbox: channel.inbox,
        conversation: conversation,
        message_type: :incoming,
        source_id: 'incoming-read-1',
        created_at: 10.minutes.ago
      )

      expect_any_instance_of(Conversation).to receive(:dispatch_conversation_updated_event) do |_instance, changes|
        expect(changes['agent_last_seen_at'].first.to_i).to eq(initial_last_seen.to_i)
        expect(changes['agent_last_seen_at'].last.to_i).to eq(message.created_at.to_i)
        expect(changes['assignee_last_seen_at'].first.to_i).to eq(initial_last_seen.to_i)
        expect(changes['assignee_last_seen_at'].last.to_i).to eq(message.created_at.to_i)
      end.and_call_original

      described_class.new(
        channel: channel,
        payload: {
          event: 'messages.update',
          data: {
            keyId: 'incoming-read-1',
            remoteJid: '15551234567@s.whatsapp.net',
            fromMe: false,
            status: 'READ'
          }
        }.with_indifferent_access
      ).perform

      expect(conversation.reload.agent_last_seen_at.to_i).to eq(message.created_at.to_i)
      expect(conversation.assignee_last_seen_at.to_i).to eq(message.created_at.to_i)
    end

    it 'schedules a backfill when a self-sent status update arrives before the local message exists' do
      delayed_job = class_double(Channels::WhatsappWeb::MessageUpdateBackfillJob, perform_later: true)

      allow(Rails.logger).to receive(:info)
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
      expect(Rails.logger).to have_received(:info).with(
        include(
          'Scheduled messages.update backfill for transient missing local message',
          'channel=',
          'source_id=outgoing-missing-1',
          'status=3',
          'wait_seconds=3'
        )
      )
      expect(
        WhatsappWeb::PendingMessageStatusCache.new(
          inbox_id: channel.inbox.id,
          source_id: 'outgoing-missing-1'
        ).peek
      ).to eq('3')
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
      expect(
        WhatsappWeb::PendingMessageStatusCache.new(
          inbox_id: channel.inbox.id,
          source_id: 'outgoing-missing-flat-1'
        ).peek
      ).to eq('DELIVERY_ACK')
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

    it 'marks transient reconnects without downgrading the channel into a hard disconnect' do
      channel.update!(
        lifecycle_state: 'connected',
        connection_state: 'open',
        qr_code: { 'base64' => 'stale-qr-code' }
      )

      described_class.new(
        channel: channel,
        payload: {
          event: 'connection.update',
          data: {
            state: 'reconnecting',
            statusReason: 408
          }
        }.with_indifferent_access
      ).perform

      channel.reload
      expect(channel.connection_state).to eq('reconnecting')
      expect(channel.lifecycle_state).to eq('reconnecting')
      expect(channel.qr_code).to eq({})
      expect(channel.last_error).to eq('status reason: 408')
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

    it 'preserves a fresh QR artifact when an auth-required status races before the QR is scanned' do
      freeze_time do
        generated_at = Time.current
        expires_at = generated_at + Channel::WhatsappWeb::AUTH_ARTIFACT_TTL
        channel.update!(
          lifecycle_state: 'qr_ready',
          connection_state: 'connecting',
          qr_code: {
            'artifact_type' => 'qr',
            'base64' => 'data:image/png;base64,abc',
            'code' => '123456',
            'generated_at' => generated_at.iso8601,
            'expires_at' => expires_at.iso8601
          },
          sync_state: channel.auth_artifact_sync_state(type: 'qr', generated_at: generated_at, expires_at: expires_at)
        )

        described_class.new(
          channel: channel,
          payload: {
            event: 'status.instance',
            data: {
              status: 'reauth_required',
              message: 'Authentication artifacts were not generated after reconnect',
              disconnectionReasonCode: 428
            }
          }.with_indifferent_access
        ).perform

        channel.reload
        expect(channel.lifecycle_state).to eq('qr_ready')
        expect(channel.connection_state).to eq('close')
        expect(channel.qr_code).to include('code' => '123456')
        expect(channel.auth_artifact_valid?).to be true
        expect(channel.last_error).to be_nil
      end
    end

    it 'marks a valid auth artifact as scanned when Evolution reports connecting without QR' do
      freeze_time do
        generated_at = 10.seconds.ago
        expires_at = generated_at + Channel::WhatsappWeb::AUTH_ARTIFACT_TTL
        channel.update!(
          lifecycle_state: 'qr_ready',
          connection_state: 'connecting',
          qr_code: {
            'artifact_type' => 'qr',
            'base64' => 'data:image/png;base64,abc',
            'code' => '123456',
            'generated_at' => generated_at.iso8601,
            'expires_at' => expires_at.iso8601
          },
          sync_state: channel.auth_artifact_sync_state(type: 'qr', generated_at: generated_at, expires_at: expires_at)
        )

        described_class.new(
          channel: channel,
          payload: {
            event: 'connection.update',
            data: {
              connection: 'connecting',
              hasQr: false
            }
          }.with_indifferent_access
        ).perform

        channel.reload
        expect(channel.lifecycle_state).to eq('qr_scanned')
        expect(channel.connection_state).to eq('connecting')
        expect(channel.qr_code).to eq({})
        expect(channel.qr_generated_at).to be_nil
        expect(channel.sync_state_payload['auth_artifact_scanned_at']).to eq(Time.current.iso8601)
        expect(channel.last_error).to be_nil
      end
    end

    it 'marks a valid auth artifact as scanned when Evolution reports no QR without a connection state' do
      freeze_time do
        generated_at = 10.seconds.ago
        expires_at = generated_at + Channel::WhatsappWeb::AUTH_ARTIFACT_TTL
        channel.update!(
          lifecycle_state: 'qr_ready',
          connection_state: 'connecting',
          qr_code: {
            'artifact_type' => 'qr',
            'base64' => 'data:image/png;base64,abc',
            'code' => '123456',
            'generated_at' => generated_at.iso8601,
            'expires_at' => expires_at.iso8601
          },
          sync_state: channel.auth_artifact_sync_state(type: 'qr', generated_at: generated_at, expires_at: expires_at)
        )

        described_class.new(
          channel: channel,
          payload: {
            event: 'connection.update',
            data: {
              hasQr: false
            }
          }.with_indifferent_access
        ).perform

        channel.reload
        expect(channel.lifecycle_state).to eq('qr_scanned')
        expect(channel.connection_state).to eq('connecting')
        expect(channel.qr_code).to eq({})
        expect(channel.qr_generated_at).to be_nil
        expect(channel.sync_state_payload['auth_artifact_scanned_at']).to eq(Time.current.iso8601)
        expect(channel.last_error).to be_nil
      end
    end

    it 'ignores automatic QR updates while a scanned artifact is still connecting' do
      channel.update!(
        lifecycle_state: 'qr_scanned',
        connection_state: 'connecting',
        qr_code: {},
        sync_state: channel.sync_state_payload.merge(
          'qr_generated_at' => nil,
          'auth_artifact_scanned_at' => Time.current.iso8601
        )
      )

      described_class.new(
        channel: channel,
        payload: {
          event: 'qrcode.updated',
          data: {
            qrcode: {
              base64: 'data:image/png;base64,new-auto-qr',
              code: 'new-auto-code'
            }
          }
        }.with_indifferent_access
      ).perform

      channel.reload
      expect(channel.lifecycle_state).to eq('qr_scanned')
      expect(channel.connection_state).to eq('connecting')
      expect(channel.qr_code).to eq({})
      expect(channel.qr_generated_at).to be_nil
    end

    it 'treats logged out status.instance events as disconnected instead of failed' do
      described_class.new(
        channel: channel,
        payload: {
          event: 'status.instance',
          data: {
            status: 'closed',
            disconnectionReasonCode: 401
          }
        }.with_indifferent_access
      ).perform

      channel.reload
      expect(channel.connection_state).to eq('close')
      expect(channel.lifecycle_state).to eq('disconnected')
    end

    it 'ignores a late runtime failure from an older lifecycle operation' do
      operation_id = channel.begin_lifecycle_operation!(kind: :reauthorize, operation_id: 'current-operation')

      described_class.new(
        channel: channel,
        payload: {
          event: 'status.instance',
          data: {
            status: 'closed',
            disconnectionReasonCode: 401,
            lifecycleOperationId: 'superseded-operation'
          }
        }.with_indifferent_access
      ).perform

      channel.reload
      expect(channel.connection_state).to eq('connecting')
      expect(channel.lifecycle_state).to eq('waiting_for_qr')
      expect(channel.lifecycle_operation_id).to eq(operation_id)
    end

    it 'accepts matching lifecycle events and records terminal completion', :aggregate_failures do
      operation_id = channel.begin_lifecycle_operation!(kind: :reauthorize, operation_id: 'current-operation')

      described_class.new(
        channel: channel,
        payload: {
          event: 'qrcode.updated',
          data: {
            lifecycleOperationId: operation_id,
            lifecycleEventSequence: 1,
            qrcode: { base64: 'data:image/png;base64,current', code: 'current-code' }
          }
        }.with_indifferent_access
      ).perform

      channel.reload
      expect(channel.lifecycle_state).to eq('qr_ready')
      expect(channel.lifecycle_operation_id).to eq(operation_id)

      described_class.new(
        channel: channel,
        payload: {
          event: 'connection.update',
          data: { state: 'open', lifecycleOperationId: operation_id, lifecycleEventSequence: 3 }
        }.with_indifferent_access
      ).perform

      channel.reload
      expect(channel.connection_state).to eq('open')
      expect(channel.lifecycle_state).to eq('connected')
      expect(channel.lifecycle_operation_id).to eq(operation_id)
      expect(channel).not_to be_lifecycle_operation_pending
      expect(channel.sync_state_payload['lifecycle_operation_completed_at']).to be_present

      described_class.new(
        channel: channel,
        payload: {
          event: 'status.instance',
          data: {
            status: 'closed',
            disconnectionReasonCode: 401,
            lifecycleOperationId: operation_id,
            lifecycleEventSequence: 2
          }
        }.with_indifferent_access
      ).perform

      channel.reload
      expect(channel.connection_state).to eq('open')
      expect(channel.lifecycle_state).to eq('connected')
    end

    it 'does not adopt an unfenced terminal callback from an unknown operation' do
      channel.update!(connection_state: 'open', lifecycle_state: 'connected')

      described_class.new(
        channel: channel,
        payload: {
          event: 'status.instance',
          data: {
            status: 'closed',
            disconnectionReasonCode: 401,
            lifecycleOperationId: 'unknown-operation',
            lifecycleEventSequence: 1
          }
        }.with_indifferent_access
      ).perform

      channel.reload
      expect(channel.connection_state).to eq('open')
      expect(channel.lifecycle_state).to eq('connected')
      expect(channel.lifecycle_operation_id).to be_nil
    end

    it 'adopts a sequenced open callback when there is no active causal fence' do
      described_class.new(
        channel: channel,
        payload: {
          event: 'connection.update',
          data: {
            state: 'open',
            lifecycleOperationId: 'reconciled-operation',
            lifecycleEventSequence: 4
          }
        }.with_indifferent_access
      ).perform

      channel.reload
      expect(channel.connection_state).to eq('open')
      expect(channel.lifecycle_operation_id).to eq('reconciled-operation')
      expect(channel.sync_state_payload['lifecycle_operation_completed_at']).to be_present
    end

    it 'ignores an older open event after a newer authoritative disconnect' do
      described_class.new(
        channel: channel,
        payload: {
          event: 'status.instance',
          date_time: '2026-07-24T15:42:00.000Z',
          data: { status: 'closed', disconnectionReasonCode: 401 }
        }.with_indifferent_access
      ).perform

      described_class.new(
        channel: channel,
        payload: {
          event: 'connection.update',
          date_time: '2026-07-24T15:41:59.000Z',
          data: { state: 'open' }
        }.with_indifferent_access
      ).perform

      channel.reload
      expect(channel.connection_state).to eq('close')
      expect(channel.lifecycle_state).to eq('disconnected')
      expect(channel.sync_state_payload['last_runtime_event_at']).to eq('2026-07-24T15:42:00Z')
    end

    it 'ignores delayed authentication failures older than the current runtime watermark' do
      channel.update!(
        connection_state: 'open',
        lifecycle_state: 'connected',
        sync_state: channel.sync_state_payload.merge('last_runtime_event_at' => '2026-07-24T15:43:00Z')
      )

      described_class.new(
        channel: channel,
        payload: {
          event: 'status.instance',
          date_time: '2026-07-24T15:42:00.000Z',
          data: { status: 'closed', disconnectionReasonCode: 401 }
        }.with_indifferent_access
      ).perform
      described_class.new(
        channel: channel,
        payload: {
          event: 'connection.update',
          date_time: '2026-07-24T15:42:30.000Z',
          data: { state: 'open' }
        }.with_indifferent_access
      ).perform

      channel.reload
      expect(channel.connection_state).to eq('open')
      expect(channel.lifecycle_state).to eq('connected')
      expect(channel.sync_state_payload['last_runtime_event_at']).to eq('2026-07-24T15:43:00Z')
    end

    it 'treats reauth_required status.instance events as disconnected instead of failed' do
      described_class.new(
        channel: channel,
        payload: {
          event: 'status.instance',
          data: {
            status: 'reauth_required',
            message: 'Authentication artifacts were not generated after reconnect',
            disconnectionReasonCode: 428
          }
        }.with_indifferent_access
      ).perform

      channel.reload
      expect(channel.connection_state).to eq('close')
      expect(channel.lifecycle_state).to eq('disconnected')
      expect(channel.last_error).to include('Authentication artifacts were not generated after reconnect')
    end

    it 'marks logout.instance events as disconnected and clears stale errors' do
      channel.update!(last_error: 'Previous provider error')

      described_class.new(
        channel: channel,
        payload: {
          event: 'logout.instance',
          data: nil
        }.with_indifferent_access
      ).perform

      channel.reload
      expect(channel.connection_state).to eq('close')
      expect(channel.lifecycle_state).to eq('disconnected')
      expect(channel.last_error).to be_nil
    end

    it 'marks remove.instance events as disconnected with an actionable repair hint' do
      described_class.new(
        channel: channel,
        payload: {
          event: 'remove.instance',
          data: nil
        }.with_indifferent_access
      ).perform

      channel.reload
      expect(channel.connection_state).to eq('close')
      expect(channel.lifecycle_state).to eq('disconnected')
      expect(channel.last_error).to eq(
        'Evolution instance was removed. Run repair or reconnect to create a new session.'
      )
    end

    it 'treats messages.set as a successful connection without starting an early history sync' do
      channel.update!(connection_state: 'open', lifecycle_state: 'waiting_for_qr')
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

    it 'does not let a late history batch resurrect a disconnected runtime' do
      channel.update!(connection_state: 'close', lifecycle_state: 'disconnected')

      described_class.new(
        channel: channel,
        payload: {
          event: 'messages.set',
          data: []
        }.with_indifferent_access
      ).perform

      channel.reload
      expect(channel.connection_state).to eq('close')
      expect(channel.lifecycle_state).to eq('disconnected')
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
