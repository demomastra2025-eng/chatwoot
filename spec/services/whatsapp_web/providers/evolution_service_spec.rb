require 'rails_helper'

describe WhatsappWeb::Providers::EvolutionService do
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

  describe '#refresh_qr!' do
    it 'provisions the instance when Evolution reports it missing' do
      service = described_class.new(channel: channel)
      missing_instance_error = described_class::RequestError.new(
        'instance does not exist',
        status: 404,
        body: {}
      )

      allow(service).to receive(:request)
        .with(:get, "/instance/connect/#{channel.instance_name}?number=#{channel.pairing_number}")
        .and_raise(missing_instance_error)
      allow(service).to receive(:provision!).and_return(channel)

      expect(service.refresh_qr!).to eq(channel)
      expect(service).to have_received(:provision!)
    end

    it 'stores a provider error when Evolution refuses to generate another QR code' do
      service = described_class.new(channel: channel)

      allow(service).to receive(:request)
        .with(:get, "/instance/connect/#{channel.instance_name}?number=#{channel.pairing_number}")
        .and_return(
          'message' => 'QR code limit reached, please login again',
          'statusCode' => 500
        )

      expect(service.refresh_qr!).to eq(channel)
      expect(channel.reload.lifecycle_state).to eq('failed')
      expect(channel.connection_state).to eq('refused')
      expect(channel.last_error).to eq('QR code limit reached, please login again | status code: 500')
    end
  end

  describe '#provision!' do
    it 'reapplies webhook and settings after creating the instance' do
      service = described_class.new(channel: channel)
      response = { 'instance' => { 'state' => 'connecting' }, 'qrcode' => { 'code' => '123456' } }

      allow(service).to receive(:instance_exists?).and_return(false)
      allow(service).to receive(:request).with(:post, '/instance/create', body: anything).and_return(response)
      allow(service).to receive(:request).with(:post, "/webhook/set/#{channel.instance_name}", body: anything).and_return({})
      allow(service).to receive(:request).with(:post, "/settings/set/#{channel.instance_name}", body: anything).and_return({})

      service.provision!

      expect(service).to have_received(:request).with(:post, "/webhook/set/#{channel.instance_name}", body: anything)
      expect(service).to have_received(:request).with(:post, "/settings/set/#{channel.instance_name}", body: anything)
    end

    it 'recreates a broken existing instance when repair fails with provider 500' do
      service = described_class.new(channel: channel)
      response = { 'instance' => { 'state' => 'connecting' }, 'qrcode' => { 'code' => '123456' } }
      provider_error = described_class::RequestError.new(
        'Internal Server Error',
        status: 500,
        body: { 'message' => 'Internal Server Error' }
      )

      allow(service).to receive(:instance_exists?).and_return(true)
      allow(service).to receive(:repair!).and_raise(provider_error)
      allow(service).to receive(:request).with(:delete, "/instance/delete/#{channel.instance_name}").and_return({})
      allow(service).to receive(:request).with(:post, '/instance/create', body: anything).and_return(response)
      allow(service).to receive(:request).with(:post, "/webhook/set/#{channel.instance_name}", body: anything).and_return({})
      allow(service).to receive(:request).with(:post, "/settings/set/#{channel.instance_name}", body: anything).and_return({})

      service.provision!

      expect(service).to have_received(:request).with(:delete, "/instance/delete/#{channel.instance_name}")
      expect(service).to have_received(:request).with(:post, '/instance/create', body: anything)
      expect(service).to have_received(:request).with(:post, "/webhook/set/#{channel.instance_name}", body: anything)
      expect(service).to have_received(:request).with(:post, "/settings/set/#{channel.instance_name}", body: anything)
    end
  end

  describe '#repair!' do
    it 'reapplies webhook and settings before syncing state' do
      service = described_class.new(channel: channel)

      allow(service).to receive(:request).with(:post, "/webhook/set/#{channel.instance_name}", body: anything).and_return({})
      allow(service).to receive(:request).with(:post, "/settings/set/#{channel.instance_name}", body: anything).and_return({})
      allow(service).to receive(:sync_connection_state!).and_return(channel)
      allow(service).to receive(:refresh_qr!).and_return(channel)

      service.repair!

      expect(service).to have_received(:request).with(:post, "/webhook/set/#{channel.instance_name}", body: anything)
      expect(service).to have_received(:request).with(:post, "/settings/set/#{channel.instance_name}", body: anything)
    end

    it 'does not force a fresh qr while Evolution is already reconnecting automatically' do
      service = described_class.new(channel: channel)

      allow(service).to receive(:request).with(:post, "/webhook/set/#{channel.instance_name}", body: anything).and_return({})
      allow(service).to receive(:request).with(:post, "/settings/set/#{channel.instance_name}", body: anything).and_return({})
      allow(service).to receive(:sync_connection_state!) do
        channel.update!(connection_state: 'reconnecting', lifecycle_state: 'reconnecting')
      end
      allow(service).to receive(:refresh_qr!).and_return(channel)

      service.repair!

      expect(service).not_to have_received(:refresh_qr!)
    end
  end

  describe '#reconnect!' do
    it 'restarts the runtime session while Evolution is already reconnecting' do
      service = described_class.new(channel: channel)
      channel.update!(connection_state: 'reconnecting', lifecycle_state: 'reconnecting')
      expect(service).not_to receive(:refresh_qr!)

      allow(service).to receive(:request)
        .with(:post, "/instance/restart/#{channel.instance_name}", body: {})
        .and_return({ 'instance' => { 'state' => 'reconnecting' } })
      allow(service).to receive(:sync_from_runtime_response!).and_return(channel)

      service.reconnect!

      expect(service).to have_received(:request)
        .with(:post, "/instance/restart/#{channel.instance_name}", body: {})
    end
  end

  describe '#sync_connection_state!' do
    it 'clears the stored qr code when the runtime is already connected' do
      service = described_class.new(channel: channel)
      channel.update!(
        qr_code: { 'base64' => 'stale-qr-code' },
        lifecycle_state: 'qr_ready',
        connection_state: 'connecting'
      )

      allow(service).to receive(:request)
        .with(:get, "/instance/connectionState/#{channel.instance_name}")
        .and_return({ 'instance' => { 'state' => 'open' } })

      service.sync_connection_state!

      expect(channel.reload.connection_state).to eq('open')
      expect(channel.lifecycle_state).to eq('connected')
      expect(channel.qr_code).to eq({})
    end

    it 'preserves the last provider error when status sync only reports a refused state' do
      service = described_class.new(channel: channel)
      channel.update!(
        lifecycle_state: 'failed',
        connection_state: 'refused',
        last_error: 'QR code limit reached, please login again | status code: 500'
      )

      allow(service).to receive(:request)
        .with(:get, "/instance/connectionState/#{channel.instance_name}")
        .and_return({ 'instance' => { 'state' => 'refused' } })

      service.sync_connection_state!

      expect(channel.reload.last_error).to eq('QR code limit reached, please login again | status code: 500')
      expect(channel.connection_state).to eq('refused')
      expect(channel.lifecycle_state).to eq('failed')
    end

    it 'keeps reconnecting sessions in a transient reconnecting lifecycle state' do
      service = described_class.new(channel: channel)

      allow(service).to receive(:request)
        .with(:get, "/instance/connectionState/#{channel.instance_name}")
        .and_return({ 'instance' => { 'state' => 'reconnecting' } })

      service.sync_connection_state!

      channel.reload
      expect(channel.connection_state).to eq('reconnecting')
      expect(channel.lifecycle_state).to eq('reconnecting')
      expect(channel.last_error).to be_nil
    end
  end

  describe 'runtime payloads' do
    it 'subscribes to the lightweight history, contact, and label events needed by Onelink' do
      service = described_class.new(channel: channel)
      events = service.send(:webhook_payload).dig(:webhook, :events)

      expect(events).to include(
        'CALL',
        'CONTACTS_UPSERT',
        'LABELS_EDIT',
        'LABELS_ASSOCIATION',
        'MESSAGING_HISTORY_SET',
        'STATUS_INSTANCE',
        'LOGOUT_INSTANCE',
        'REMOVE_INSTANCE'
      )
      expect(events).not_to include('MESSAGES_SET')
    end

    it 'sends the full settings payload required by Evolution validation' do
      service = described_class.new(channel: channel)

      expect(service.send(:settings_payload)).to eq(
        rejectCall: false,
        groupsIgnore: false,
        alwaysOnline: false,
        readMessages: false,
        readStatus: false,
        syncFullHistory: true
      )
    end
  end

  describe '#fetch_message_by_source_id' do
    it 'looks up a stored provider message by key.id' do
      service = described_class.new(channel: channel)

      allow(service).to receive(:request)
        .with(
          :post,
          "/chat/findMessages/#{channel.instance_name}",
          body: hash_including(
            where: {
              key: {
                id: 'WA-MSG-1',
                fromMe: true,
                remoteJid: '15551234567@s.whatsapp.net'
              }
            }
          )
        )
        .and_return(
          'messages' => {
            'records' => [
              { 'key' => { 'id' => 'WA-MSG-1' }, 'message' => { 'conversation' => 'Hello' } }
            ]
          }
        )

      response = service.fetch_message_by_source_id(
        source_id: 'WA-MSG-1',
        remote_jid: '15551234567@s.whatsapp.net',
        from_me: true
      )

      expect(response.dig('key', 'id')).to eq('WA-MSG-1')
    end
  end

  describe '#mark_messages_read' do
    it 'posts the normalized read payload to Evolution' do
      service = described_class.new(channel: channel)

      expect(service).to receive(:request).with(
        :post,
        "/chat/markMessageAsRead/#{channel.instance_name}",
        body: {
          readMessages: [
            {
              remoteJid: '15551234567@s.whatsapp.net',
              fromMe: false,
              id: 'wa-read-1'
            }
          ]
        }
      ).and_return({})

      service.mark_messages_read(messages: [
                                   {
                                     remoteJid: '15551234567',
                                     fromMe: false,
                                     id: 'wa-read-1'
                                   }
                                 ])
    end
  end

  describe '#update_message' do
    it 'posts the normalized edit payload to Evolution' do
      service = described_class.new(channel: channel)
      conversation = create(:conversation, account: channel.account, inbox: channel.inbox)
      message = create(
        :message,
        account: channel.account,
        inbox: channel.inbox,
        conversation: conversation,
        message_type: :outgoing,
        content: 'Original text',
        source_id: 'wa-edit-1'
      )

      expect(service).to receive(:request).with(
        :post,
        "/chat/updateMessage/#{channel.instance_name}",
        body: {
          number: "#{conversation.contact_inbox.source_id}@s.whatsapp.net",
          text: 'Edited text',
          key: {
            id: 'wa-edit-1',
            fromMe: true,
            remoteJid: "#{conversation.contact_inbox.source_id}@s.whatsapp.net"
          }
        }
      ).and_return({})

      service.update_message(message: message, content: 'Edited text')
    end
  end

  describe '#fetch_message_media' do
    it 'fetches base64 media payload for a stored provider message' do
      service = described_class.new(channel: channel)
      record = {
        key: {
          id: 'WA-MSG-MEDIA-1',
          remoteJid: '15551234567@s.whatsapp.net',
          fromMe: false
        },
        message: {
          imageMessage: {
            mimetype: 'image/png',
            url: 'https://example.com/image.png'
          }
        }
      }

      allow(service).to receive(:request)
        .with(
          :post,
          "/chat/getBase64FromMediaMessage/#{channel.instance_name}",
          body: {
            message: record,
            convertToMp4: false
          }
        )
        .and_return(
          'base64' => Base64.strict_encode64('image-bytes'),
          'fileName' => 'image.png',
          'mimetype' => 'image/png'
        )

      response = service.fetch_message_media(record: record)

      expect(response[:base64]).to eq(Base64.strict_encode64('image-bytes'))
      expect(response[:fileName]).to eq('image.png')
      expect(response[:mimetype]).to eq('image/png')
    end
  end

  describe '#prefer_provider_media_for_history?' do
    it 'uses provider media as the primary source for historical attachments' do
      service = described_class.new(channel: channel)

      expect(service.prefer_provider_media_for_history?).to be(true)
    end
  end

  describe '#diagnostics' do
    it 'includes echo backlog and status-miss counters' do
      service = described_class.new(channel: channel)
      channel.record_echo_status_miss!(source_id: 'WA-MISS-1')

      allow(service).to receive(:pending_echo_jobs_snapshot).and_return(
        backlog: 3,
        oldest_pending_at: Time.zone.parse('2026-03-13T12:00:00Z')
      )

      diagnostics = service.diagnostics

      expect(diagnostics.dig(:counts, :echo_jobs_backlog)).to eq(3)
      expect(diagnostics.dig(:counts, :messages_update_without_local_source_id_hit_count)).to eq(1)
      expect(diagnostics.dig(:runtime, :oldest_pending_echo_job_at)).to eq('2026-03-13T12:00:00Z')
    end
  end

  describe '#send_message' do
    it 'signs outgoing text messages using the configured delimiter' do
      signed_channel = create(:channel_whatsapp_web, sign_messages: true, sign_delimiter: '\\n')
      service = described_class.new(channel: signed_channel)
      agent = create(:user, account: signed_channel.account, name: 'Alice Agent')
      contact = create(:contact, account: signed_channel.account, phone_number: '+15551234567')
      contact_inbox = create(:contact_inbox, inbox: signed_channel.inbox, contact: contact, source_id: '15551234567')
      conversation = create(
        :conversation,
        account: signed_channel.account,
        inbox: signed_channel.inbox,
        contact: contact,
        contact_inbox: contact_inbox
      )
      message = create(
        :message,
        account: signed_channel.account,
        inbox: signed_channel.inbox,
        conversation: conversation,
        sender: agent,
        message_type: :outgoing
      )

      allow(message).to receive(:outgoing_content).and_return('Hello from support')
      allow(service).to receive(:request)
        .with(
          :post,
          "/message/sendText/#{signed_channel.instance_name}",
          body: hash_including(
            number: '15551234567',
            text: "*Alice Agent:*\nHello from support"
          )
        )
        .and_return({ 'key' => { 'id' => 'provider-message-id' } })

      expect(service.send_message(message)).to eq('provider-message-id')
    end
  end
end
