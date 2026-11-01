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
  let(:valid_webhook_response) { { 'enabled' => true, 'url' => channel.webhook_callback_url } }

  describe '#request' do
    it 'normalizes Evolution deleting-instance JSON errors before raising' do
      service = described_class.new(channel: channel)
      response = instance_double(
        HTTParty::Response,
        success?: false,
        code: 400,
        body: {
          status: 400,
          error: 'Bad Request',
          message: ["The \"#{channel.instance_name}\" instance is being deleted"]
        }.to_json,
        parsed_response: {
          'status' => 400,
          'error' => 'Bad Request',
          'message' => ["The \"#{channel.instance_name}\" instance is being deleted"]
        }
      )

      expect(HTTParty).to receive(:get)
        .with(
          "https://evolution.example.com/instance/connect/#{channel.instance_name}",
          hash_including(timeout: 20)
        ).and_return(response)

      expect do
        service.send(:request, :get, "/instance/connect/#{channel.instance_name}")
      end.to raise_error(described_class::RequestError, Channel::WhatsappWeb::INSTANCE_BEING_DELETED_MESSAGE)
    end

    it 'raises when Evolution returns an error payload with HTTP 200' do
      service = described_class.new(channel: channel)
      response = instance_double(
        HTTParty::Response,
        success?: true,
        code: 200,
        body: { error: true, statusCode: 500, message: 'provider failed' }.to_json,
        parsed_response: { 'error' => true, 'statusCode' => 500, 'message' => 'provider failed' }
      )

      allow(HTTParty).to receive(:post).and_return(response)

      expect do
        service.send(:request, :post, "/instance/restart/#{channel.instance_name}", body: {})
      end.to raise_error(described_class::RequestError) { |error| expect(error.status).to eq(500) }
    end
  end

  describe '#refresh_qr!' do
    it 'returns a saved fresh QR artifact without calling Evolution again' do
      service = described_class.new(channel: channel)
      generated_at = Time.current
      expires_at = generated_at + Channel::WhatsappWeb::AUTH_ARTIFACT_TTL
      channel.update!(
        connection_state: 'connecting',
        lifecycle_state: 'qr_ready',
        qr_code: {
          'artifact_type' => 'qr',
          'base64' => 'saved-qr',
          'code' => 'saved-code',
          'generated_at' => generated_at.iso8601,
          'expires_at' => expires_at.iso8601
        },
        sync_state: channel.sync_state_payload.merge(
          'qr_generated_at' => generated_at.iso8601,
          'auth_artifact_type' => 'qr',
          'auth_artifact_expires_at' => expires_at.iso8601
        )
      )

      expect(service).not_to receive(:request)

      expect(service.refresh_qr!(artifact_type: 'qr')).to eq(channel)
      expect(channel.reload.qr_code).to include('base64' => 'saved-qr', 'code' => 'saved-code')
    end

    it 'requests a QR artifact without pairing number and stores only QR data' do
      service = described_class.new(channel: channel)

      allow(service).to receive(:request)
        .with(:get, "/instance/connect/#{channel.instance_name}")
        .and_return(
          'instance' => { 'state' => 'connecting', 'status' => 'qr_ready' },
          'qrcode' => {
            'base64' => 'fresh-qr',
            'code' => 'qr-code-value',
            'pairingCode' => 'ABCD1234'
          }
        )

      expect(service.refresh_qr!(artifact_type: 'qr')).to eq(channel)
      expect(channel.reload.qr_code).to include('artifact_type' => 'qr', 'base64' => 'fresh-qr', 'code' => 'qr-code-value')
      expect(channel.qr_code).not_to include('pairingCode')
      expect(channel.auth_artifact_valid?).to be true
    end

    it 'requests a pairing-code artifact with pairing number and stores only pairing data' do
      service = described_class.new(channel: channel)

      allow(service).to receive(:request)
        .with(:get, "/instance/connect/#{channel.instance_name}?number=#{channel.pairing_number}")
        .and_return(
          'instance' => { 'state' => 'connecting', 'status' => 'qr_ready' },
          'qrcode' => {
            'base64' => 'fresh-qr',
            'code' => 'qr-code-value',
            'pairingCode' => 'ABCD1234'
          }
        )

      expect(service.refresh_qr!(artifact_type: 'code')).to eq(channel)
      expect(channel.reload.qr_code).to include('artifact_type' => 'pairing_code', 'pairingCode' => 'ABCD1234')
      expect(channel.qr_code).not_to include('base64')
      expect(channel.qr_code).not_to include('code')
      expect(channel.auth_artifact_valid?).to be true
    end

    it 'provisions the instance when Evolution reports it missing' do
      service = described_class.new(channel: channel)
      missing_instance_error = described_class::RequestError.new(
        'instance does not exist',
        status: 404,
        body: {}
      )

      allow(service).to receive(:request)
        .with(:get, "/instance/connect/#{channel.instance_name}")
        .and_raise(missing_instance_error)
      allow(service).to receive(:provision!).and_return(channel)

      expect(service.refresh_qr!).to eq(channel)
      expect(service).to have_received(:provision!)
    end

    it 'stores a provider error when Evolution refuses to generate another QR code' do
      service = described_class.new(channel: channel)

      allow(service).to receive(:request)
        .with(:get, "/instance/connect/#{channel.instance_name}")
        .and_return(
          'message' => 'QR code limit reached, please login again',
          'statusCode' => 500
        )

      expect(service.refresh_qr!).to eq(channel)
      expect(channel.reload.lifecycle_state).to eq('failed')
      expect(channel.connection_state).to eq('refused')
      expect(channel.last_error).to eq('QR code limit reached, please login again | status code: 500')
    end

    it 'treats explicit reauth_required outcomes as disconnected instead of waiting for qr' do
      service = described_class.new(channel: channel)

      allow(service).to receive(:request)
        .with(:get, "/instance/connect/#{channel.instance_name}")
        .and_return(
          'instance' => { 'state' => 'connecting', 'status' => 'reauth_required' },
          'status' => 'reauth_required',
          'message' => 'Authentication artifacts were not generated after reconnect',
          'statusCode' => 401,
          'qrcode' => { 'count' => 0 }
        )

      expect(service.refresh_qr!).to eq(channel)
      expect(channel.reload.lifecycle_state).to eq('disconnected')
      expect(channel.connection_state).to eq('close')
      expect(channel.last_error).to eq(
        'Authentication artifacts were not generated after reconnect | reauth_required | status code: 401'
      )
    end
  end

  describe '#provision!' do
    it 'reapplies webhook and settings after creating the instance' do
      service = described_class.new(channel: channel)
      response = { 'instance' => { 'state' => 'connecting' }, 'qrcode' => { 'code' => '123456' } }

      allow(service).to receive(:instance_exists?).and_return(false)
      allow(service).to receive(:request).with(:post, '/instance/create', body: anything).and_return(response)
      allow(service).to receive(:request).with(:post, "/webhook/set/#{channel.instance_name}", body: anything)
                                         .and_return(valid_webhook_response)
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
      allow(service).to receive(:request).with(:post, "/webhook/set/#{channel.instance_name}", body: anything)
                                         .and_return(valid_webhook_response)
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

      allow(service).to receive(:request).with(:post, "/webhook/set/#{channel.instance_name}", body: anything)
                                         .and_return(valid_webhook_response)
      allow(service).to receive(:request).with(:post, "/settings/set/#{channel.instance_name}", body: anything).and_return({})
      allow(service).to receive(:sync_connection_state!).and_return(channel)
      allow(service).to receive(:refresh_qr!).and_return(channel)

      service.repair!

      expect(service).to have_received(:request).with(:post, "/webhook/set/#{channel.instance_name}", body: anything)
      expect(service).to have_received(:request).with(:post, "/settings/set/#{channel.instance_name}", body: anything)
    end

    it 'fails repair when Evolution keeps a stale webhook target' do
      service = described_class.new(channel: channel)
      allow(service).to receive(:request)
        .with(:post, "/webhook/set/#{channel.instance_name}", body: anything)
        .and_return('enabled' => true, 'url' => 'https://app.example.com/webhooks/whatsapp_web/stale')

      expect { service.repair! }
        .to raise_error(described_class::RequestError, /did not persist the expected/)
      expect(service).not_to have_received(:request)
        .with(:post, "/settings/set/#{channel.instance_name}", body: anything)
    end

    it 'fails repair when Evolution does not confirm the persisted webhook target' do
      service = described_class.new(channel: channel)
      allow(service).to receive(:request)
        .with(:post, "/webhook/set/#{channel.instance_name}", body: anything)
        .and_return({})

      expect { service.repair! }
        .to raise_error(described_class::RequestError, /did not persist the expected/)
    end

    it 'does not request fresh auth artifacts when repair leaves the session disconnected' do
      service = described_class.new(channel: channel)

      allow(service).to receive(:request).with(:post, "/webhook/set/#{channel.instance_name}", body: anything)
                                         .and_return(valid_webhook_response)
      allow(service).to receive(:request).with(:post, "/settings/set/#{channel.instance_name}", body: anything).and_return({})
      allow(service).to receive(:sync_connection_state!) do
        channel.update!(connection_state: 'close', lifecycle_state: 'disconnected', qr_code: {})
      end
      allow(service).to receive(:refresh_qr!).and_return(channel)

      service.repair!

      expect(service).not_to have_received(:refresh_qr!)
    end

    it 'does not force a fresh qr while Evolution is already reconnecting automatically' do
      service = described_class.new(channel: channel)

      allow(service).to receive(:request).with(:post, "/webhook/set/#{channel.instance_name}", body: anything)
                                         .and_return(valid_webhook_response)
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
    it 'does not request fresh auth artifacts when reconnect leaves the session disconnected' do
      service = described_class.new(channel: channel)
      allow(service).to receive(:sync_connection_state!) do
        channel.update!(connection_state: 'close', lifecycle_state: 'disconnected', qr_code: {})
      end
      allow(service).to receive(:request).with(:post, "/webhook/set/#{channel.instance_name}", body: anything)
                                         .and_return(valid_webhook_response)
      allow(service).to receive(:request).with(:post, "/settings/set/#{channel.instance_name}", body: anything).and_return({})
      allow(service).to receive(:refresh_qr!).and_return(channel)

      expect(service).not_to receive(:request).with(:post, "/instance/restart/#{channel.instance_name}", body: {})

      expect(service.reconnect!).to eq(channel)
      expect(channel.reload.qr_code).to eq({})
      expect(service).not_to have_received(:refresh_qr!)
    end

    it 'restarts an open session and skips qr refresh when the session comes back open' do
      service = described_class.new(channel: channel)
      allow(service).to receive(:sync_connection_state!) do
        channel.update!(connection_state: 'open', lifecycle_state: 'connected', qr_code: {})
      end

      allow(service).to receive(:request)
        .with(:post, "/instance/restart/#{channel.instance_name}", body: {})
        .and_return({ 'instance' => { 'state' => 'open' } })
      allow(service).to receive(:sync_from_runtime_response!) do
        channel.update!(connection_state: 'open', lifecycle_state: 'connected', qr_code: {})
      end
      allow(service).to receive(:request).with(:post, "/webhook/set/#{channel.instance_name}", body: anything)
                                         .and_return(valid_webhook_response)
      allow(service).to receive(:request).with(:post, "/settings/set/#{channel.instance_name}", body: anything).and_return({})
      allow(service).to receive(:refresh_qr!).and_return(channel)

      service.reconnect!

      expect(service).to have_received(:request)
        .with(:post, "/instance/restart/#{channel.instance_name}", body: {})
      expect(service).not_to have_received(:refresh_qr!)
    end
  end

  describe '#reauthorize!' do
    it 'accepts the asynchronous authorization cycle without waiting for a QR' do
      service = described_class.new(channel: channel)
      response = {
        'accepted' => true,
        'lifecycleOperationId' => 'provider-operation',
        'startedAt' => Time.current.iso8601,
        'instance' => { 'state' => 'reauthorizing' }
      }

      allow(service).to receive(:request)
        .with(
          :post,
          "/instance/reauthorize/#{channel.instance_name}",
          body: hash_including(lifecycleOperationId: kind_of(String))
        )
        .and_return(response)
      allow(service).to receive(:apply_runtime_configuration!)

      expect(service.reauthorize!).to eq(channel)
      expect(channel.reload).to have_attributes(connection_state: 'connecting', lifecycle_state: 'waiting_for_qr')
      expect(channel.qr_code).to eq({})
      expect(channel.lifecycle_operation_id).to eq('provider-operation')
      expect(service).to have_received(:apply_runtime_configuration!)
    end

    it 'keeps the causal operation pending when the acknowledgement arrives after the HTTP timeout' do
      service = described_class.new(channel: channel)
      allow(service).to receive(:apply_runtime_configuration!)
      allow(service).to receive(:request).and_raise(Net::ReadTimeout)

      expect(service.reauthorize!).to eq(channel)
      expect(channel.reload).to be_lifecycle_operation_pending
      expect(channel).to have_attributes(connection_state: 'connecting', lifecycle_state: 'waiting_for_qr')
      expect(service).to have_received(:apply_runtime_configuration!)
    end
  end

  describe '#disconnect!' do
    it 'marks the channel disconnected only after Evolution confirms close' do
      service = described_class.new(channel: channel)
      allow(service).to receive(:request)
        .with(:delete, "/instance/logout/#{channel.instance_name}")
        .and_return({ 'instance' => { 'state' => 'close' } })

      service.disconnect!

      expect(channel.reload).to have_attributes(connection_state: 'close', lifecycle_state: 'disconnected')
      expect(channel.sync_state_payload['last_runtime_event_at']).to be_present
    end

    it 'forgets the provider activity once the login is gone' do
      channel.update!(lifecycle_state: 'connected', connection_state: 'open')
      channel.record_provider_activity!
      service = described_class.new(channel: channel)
      allow(service).to receive(:request)
        .with(:delete, "/instance/logout/#{channel.instance_name}")
        .and_return({ 'instance' => { 'state' => 'close' } })

      service.disconnect!

      expect(channel.reload.last_provider_activity_at).to be_nil
    end

    it 'does not report success while Evolution still reports open' do
      service = described_class.new(channel: channel)
      allow(service).to receive(:request)
        .with(:delete, "/instance/logout/#{channel.instance_name}")
        .and_return({ 'instance' => { 'state' => 'open' } })
      allow(service).to receive(:request)
        .with(:get, "/instance/connectionState/#{channel.instance_name}")
        .and_return({ 'instance' => { 'state' => 'open' } })
      allow(service).to receive(:sleep)

      expect { service.disconnect! }.to raise_error(described_class::RequestError, /did not disconnect/)
    end
  end

  describe '#sync_connection_state!' do
    it 'keeps the provider observation and local state write inside one row lock' do
      service = described_class.new(channel: channel)
      inside_row_lock = false
      allow(channel).to receive(:with_lock) do |&operation|
        inside_row_lock = true
        operation.call
      ensure
        inside_row_lock = false
      end
      allow(service).to receive(:request)
        .with(:get, "/instance/connectionState/#{channel.instance_name}") do
          expect(inside_row_lock).to be(true)
          { 'instance' => { 'state' => 'close' } }
        end

      service.sync_connection_state!

      expect(inside_row_lock).to be(false)
      expect(channel.reload.connection_state).to eq('close')
    end

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
      expect(channel.sync_state_payload['last_runtime_event_at']).to be_present
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

    it 'preserves a provider lifecycle fence while asynchronous reauthorization is running' do
      service = described_class.new(channel: channel)
      operation_id = channel.begin_lifecycle_operation!(kind: :reauthorize, operation_id: 'operation-1')

      allow(service).to receive(:request)
        .with(:get, "/instance/connectionState/#{channel.instance_name}")
        .and_return({
                      'instance' => {
                        'state' => 'reauthorizing',
                        'lifecycleOperationId' => operation_id
                      }
                    })

      service.sync_connection_state!

      channel.reload
      expect(channel.connection_state).to eq('connecting')
      expect(channel.lifecycle_state).to eq('waiting_for_qr')
      expect(channel.lifecycle_operation_id).to eq(operation_id)
    end

    it 'adopts and completes a newer provider operation through bounded status reconciliation', :aggregate_failures do
      service = described_class.new(channel: channel)
      channel.begin_lifecycle_operation!(kind: :reauthorize, operation_id: 'old-operation')
      channel.update!(sync_state: channel.completed_lifecycle_operation_sync_state)

      allow(service).to receive(:request)
        .with(:get, "/instance/connectionState/#{channel.instance_name}")
        .and_return(
          { 'instance' => { 'state' => 'reauthorizing', 'lifecycleOperationId' => 'new-operation' } },
          { 'instance' => { 'state' => 'open', 'lifecycleOperationId' => 'new-operation' } }
        )

      service.sync_connection_state!

      expect(channel.reload.lifecycle_operation_id).to eq('new-operation')
      expect(channel).to be_lifecycle_operation_pending
      expect(channel.sync_state_payload['lifecycle_operation_completed_at']).to be_nil

      service.sync_connection_state!

      expect(channel.reload.connection_state).to eq('open')
      expect(channel.lifecycle_operation_id).to eq('new-operation')
      expect(channel).not_to be_lifecycle_operation_pending
      expect(channel.sync_state_payload['lifecycle_operation_completed_at']).to be_present
    end

    it 'preserves a recent scanned QR lifecycle during status-only sync while still connecting' do
      service = described_class.new(channel: channel)
      channel.update!(
        qr_code: {},
        lifecycle_state: 'qr_scanned',
        connection_state: 'connecting',
        sync_state: channel.sync_state_payload.merge('auth_artifact_scanned_at' => Time.current.iso8601)
      )

      allow(service).to receive(:request)
        .with(:get, "/instance/connectionState/#{channel.instance_name}")
        .and_return({ 'instance' => { 'state' => 'connecting' } })

      service.sync_connection_state!

      channel.reload
      expect(channel.connection_state).to eq('connecting')
      expect(channel.lifecycle_state).to eq('qr_scanned')
      expect(channel.qr_code).to eq({})
    end

    it 'lets stale scanned QR lifecycles fall back to waiting_for_qr during status sync' do
      service = described_class.new(channel: channel)
      channel.update!(
        qr_code: {},
        lifecycle_state: 'qr_scanned',
        connection_state: 'connecting',
        sync_state: channel.sync_state_payload.merge('auth_artifact_scanned_at' => 5.minutes.ago.iso8601)
      )

      allow(service).to receive(:request)
        .with(:get, "/instance/connectionState/#{channel.instance_name}")
        .and_return({ 'instance' => { 'state' => 'connecting' } })

      service.sync_connection_state!

      channel.reload
      expect(channel.connection_state).to eq('connecting')
      expect(channel.lifecycle_state).to eq('waiting_for_qr')
    end
  end

  describe '#sync_connection_state! for a working channel' do
    let(:service) { described_class.new(channel: channel) }

    def stub_provider_state(*states)
      responses = states.map { |state| { 'instance' => { 'state' => state } } }
      allow(service).to receive(:request)
        .with(:get, "/instance/connectionState/#{channel.instance_name}")
        .and_return(*responses)
    end

    before do
      channel.update!(lifecycle_state: 'connected', connection_state: 'open')
    end

    it 'keeps the channel connected when a stale close arrives while the provider showed recent activity' do
      channel.record_provider_activity!(at: 1.minute.ago)
      stub_provider_state('close')

      expect(service.sync_connection_state!).to eq(channel)

      channel.reload
      expect(channel).to have_attributes(connection_state: 'open', lifecycle_state: 'connected')
      expect(channel.sync_state_payload['consecutive_close_observations']).to eq(1)
      expect(channel.sync_state_payload['last_runtime_event_at']).to be_nil
      expect(channel.last_synced_at).to be_present
    end

    it 'keeps ignoring repeated close observations for as long as recent activity lasts' do
      channel.record_provider_activity!(at: 2.minutes.ago)
      stub_provider_state('close')

      3.times { service.sync_connection_state! }

      channel.reload
      expect(channel).to have_attributes(connection_state: 'open', lifecycle_state: 'connected')
      expect(channel.sync_state_payload['consecutive_close_observations']).to eq(3)
    end

    it 'does not take an idle channel offline from a single close poll' do
      stub_provider_state('close')

      service.sync_connection_state!

      expect(channel.reload).to have_attributes(connection_state: 'open', lifecycle_state: 'connected')
      expect(channel.sync_state_payload['consecutive_close_observations']).to eq(1)
    end

    it 'does not take a working channel offline from an unrecognised provider state either' do
      channel.record_provider_activity!(at: 1.minute.ago)
      allow(service).to receive(:request)
        .with(:get, "/instance/connectionState/#{channel.instance_name}")
        .and_return({ 'instance' => {} })

      service.sync_connection_state!

      expect(channel.reload).to have_attributes(connection_state: 'open', lifecycle_state: 'connected')
      expect(channel.sync_state_payload['consecutive_close_observations']).to eq(1)
    end

    it 'accepts the close once it repeats on consecutive polls without any recent activity' do
      channel.record_provider_activity!(at: (Channel::WhatsappWeb::RECENT_PROVIDER_ACTIVITY_WINDOW + 1.minute).ago)
      stub_provider_state('close')

      service.sync_connection_state!
      expect(channel.reload.connection_state).to eq('open')

      service.sync_connection_state!

      channel.reload
      expect(channel).to have_attributes(connection_state: 'close', lifecycle_state: 'disconnected')
      expect(channel.sync_state_payload['consecutive_close_observations']).to eq(0)
    end

    it 'resets the close counter and refreshes the activity marker when the provider reports open again' do
      channel.update!(sync_state: channel.sync_state_payload.merge('consecutive_close_observations' => 1))
      stub_provider_state('open')

      freeze_time do
        service.sync_connection_state!

        channel.reload
        expect(channel.connection_state).to eq('open')
        expect(channel.sync_state_payload['consecutive_close_observations']).to eq(0)
        expect(channel.last_provider_activity_at).to be_within(1.second).of(Time.current)
      end
    end

    it 'trusts an explicit reauth_required outcome immediately even after recent activity' do
      channel.record_provider_activity!(at: 30.seconds.ago)
      stub_provider_state('reauth_required')

      service.sync_connection_state!

      expect(channel.reload).to have_attributes(connection_state: 'close', lifecycle_state: 'disconnected')
    end

    it 'applies a reconnecting state reported by the provider as before' do
      channel.record_provider_activity!(at: 30.seconds.ago)
      stub_provider_state('reconnecting')

      service.sync_connection_state!

      expect(channel.reload).to have_attributes(connection_state: 'reconnecting', lifecycle_state: 'reconnecting')
    end

    it 'does not hold a channel that is already disconnected' do
      channel.update!(lifecycle_state: 'disconnected', connection_state: 'close')
      channel.record_provider_activity!(at: 30.seconds.ago)
      stub_provider_state('close')

      service.sync_connection_state!

      expect(channel.reload).to have_attributes(connection_state: 'close', lifecycle_state: 'disconnected')
      expect(channel.sync_state_payload['last_runtime_event_at']).to be_present
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

    it 'sends qrcode false when provisioning instance so artifacts are generated only on demand' do
      service = described_class.new(channel: channel)
      response = { 'instance' => { 'state' => 'connecting' }, 'qrcode' => { 'code' => '123456' } }

      allow(service).to receive(:instance_exists?).and_return(false)
      allow(service).to receive(:request).with(
        :post,
        '/instance/create',
        body: hash_including(qrcode: false)
      ).and_return(response)
      allow(service).to receive(:request).with(:post, "/webhook/set/#{channel.instance_name}", body: anything)
                                         .and_return(valid_webhook_response)
      allow(service).to receive(:request).with(:post, "/settings/set/#{channel.instance_name}", body: anything).and_return({})

      service.provision!

      expect(service).to have_received(:request).with(
        :post,
        '/instance/create',
        body: hash_including(qrcode: false)
      )
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

    it 'falls back to querying by key.id alone when Evolution stored remoteJid as @lid' do
      service = described_class.new(channel: channel)

      expect(service).to receive(:request)
        .with(
          :post,
          "/chat/findMessages/#{channel.instance_name}",
          body: {
            page: 1,
            offset: 1,
            where: {
              key: {
                id: 'WA-LID-MSG-1',
                fromMe: false,
                remoteJid: '15551234567@s.whatsapp.net'
              }
            }
          }
        )
        .and_return('messages' => { 'records' => [] })

      expect(service).to receive(:request)
        .with(
          :post,
          "/chat/findMessages/#{channel.instance_name}",
          body: {
            page: 1,
            offset: 5,
            where: { key: { id: 'WA-LID-MSG-1' } }
          }
        )
        .and_return(
          'messages' => {
            'records' => [
              {
                'key' => { 'id' => 'WA-LID-MSG-1', 'fromMe' => false, 'remoteJid' => '248811223344@lid' },
                'message' => { 'imageMessage' => { 'mimetype' => 'image/jpeg' } }
              }
            ]
          }
        )

      response = service.fetch_message_by_source_id(
        source_id: 'WA-LID-MSG-1',
        remote_jid: '15551234567@s.whatsapp.net',
        from_me: false
      )

      expect(response.dig('key', 'id')).to eq('WA-LID-MSG-1')
      expect(response.dig('key', 'remoteJid')).to eq('248811223344@lid')
    end

    it 'handles top-level Array and messages Array payloads from Evolution findMessages without TypeError' do
      service = described_class.new(channel: channel)

      expect(service).to receive(:request)
        .with(:post, "/chat/findMessages/#{channel.instance_name}", body: hash_including(where: { key: { id: 'WA-ARR-1', fromMe: false } }))
        .and_return([{ 'key' => { 'id' => 'WA-ARR-1', 'fromMe' => false }, 'message' => { 'conversation' => 'Top array' } }])

      expect(service).to receive(:request)
        .with(:post, "/chat/findMessages/#{channel.instance_name}", body: hash_including(where: { key: { id: 'WA-ARR-2', fromMe: true } }))
        .and_return('messages' => [{ 'key' => { 'id' => 'WA-ARR-2', 'fromMe' => true }, 'message' => { 'conversation' => 'Messages array' } }])

      first = service.fetch_message_by_source_id(source_id: 'WA-ARR-1', from_me: false)
      second = service.fetch_message_by_source_id(source_id: 'WA-ARR-2', from_me: true)

      expect(first.dig('key', 'id')).to eq('WA-ARR-1')
      expect(second.dig('key', 'id')).to eq('WA-ARR-2')
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

  describe '#mark_messages_read for a hidden @lid chat' do
    it 'keeps the @lid JID in the read payload' do
      service = described_class.new(channel: channel)

      expect(service).to receive(:request).with(
        :post,
        "/chat/markMessageAsRead/#{channel.instance_name}",
        body: { readMessages: [{ remoteJid: '143907392331785@lid', fromMe: false, id: 'wa-read-1' }] }
      ).and_return({})

      service.mark_messages_read(messages: [{ remoteJid: '143907392331785@lid', fromMe: false, id: 'wa-read-1' }])
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

  describe '#delete_message' do
    it 'sends deleteMessageForEveryone payload to Evolution' do
      service = described_class.new(channel: channel)
      conversation = create(:conversation, account: channel.account, inbox: channel.inbox)
      message = create(
        :message,
        account: channel.account,
        inbox: channel.inbox,
        conversation: conversation,
        message_type: :outgoing,
        content: 'Original text',
        source_id: 'wa-del-1'
      )

      expect(service).to receive(:request).with(
        :delete,
        "/chat/deleteMessageForEveryone/#{channel.instance_name}",
        body: {
          id: 'wa-del-1',
          fromMe: true,
          remoteJid: "#{conversation.contact_inbox.source_id}@s.whatsapp.net"
        }
      ).and_return({})

      service.delete_message(message: message)
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

    it 'records provider activity once Evolution accepts the message' do
      service = described_class.new(channel: channel)
      contact = create(:contact, account: channel.account)
      contact_inbox = create(:contact_inbox, inbox: channel.inbox, contact: contact, source_id: '15551234567')
      conversation = create(:conversation, account: channel.account, inbox: channel.inbox, contact: contact, contact_inbox: contact_inbox)
      message = create(:message, account: channel.account, inbox: channel.inbox, conversation: conversation, message_type: :outgoing)
      allow(service).to receive(:request).and_return({ 'key' => { 'id' => 'provider-message-id' } })

      freeze_time do
        expect(service.send_message(message)).to eq('provider-message-id')
        expect(channel.reload.last_provider_activity_at).to be_within(1.second).of(Time.current)
      end
    end

    it 'does not record provider activity when Evolution returns no message id' do
      service = described_class.new(channel: channel)
      contact = create(:contact, account: channel.account)
      contact_inbox = create(:contact_inbox, inbox: channel.inbox, contact: contact, source_id: '15551234567')
      conversation = create(:conversation, account: channel.account, inbox: channel.inbox, contact: contact, contact_inbox: contact_inbox)
      message = create(:message, account: channel.account, inbox: channel.inbox, conversation: conversation, message_type: :outgoing)
      allow(service).to receive(:request).and_return({})

      expect(service.send_message(message)).to be_nil
      expect(channel.reload.last_provider_activity_at).to be_nil
    end

    context 'when the conversation hangs on a LID contact inbox but the contact also has a phone identity' do
      let(:phone_digits) { '77012345678' }
      let(:lid_jid) { '143907392331785@lid' }
      let(:contact) do
        create(
          :contact,
          account: channel.account,
          name: 'Mom',
          phone_number: "+#{phone_digits}",
          additional_attributes: {
            'raw_jid' => lid_jid,
            'lid_jid' => lid_jid,
            'channel_profiles' => {
              'whatsapp_web' => {
                "whatsapp_web:#{lid_jid}" => {
                  'identifier' => "whatsapp_web:#{lid_jid}",
                  'source_id' => lid_jid,
                  'raw_jid' => lid_jid,
                  'lid_jid' => lid_jid,
                  'provider' => 'whatsapp_web',
                  'provisional_whatsapp_identity' => true
                }
              }
            }
          }
        )
      end
      let!(:phone_contact_inbox) do
        create(:contact_inbox, inbox: channel.inbox, contact: contact, source_id: phone_digits).tap do |contact_inbox|
          create(
            :contact_channel_profile,
            contact_inbox: contact_inbox,
            profile_data: { 'canonical_jid' => "#{phone_digits}@s.whatsapp.net", 'lid_jid' => lid_jid }
          )
        end
      end
      let(:lid_contact_inbox) do
        create(:contact_inbox, inbox: channel.inbox, contact: contact, source_id: lid_jid).tap do |contact_inbox|
          create(:contact_channel_profile, contact_inbox: contact_inbox, profile_data: { 'raw_jid' => lid_jid, 'lid_jid' => lid_jid })
        end
      end
      let(:conversation) do
        create(:conversation, account: channel.account, inbox: channel.inbox, contact: contact, contact_inbox: lid_contact_inbox)
      end
      let(:message) do
        create(:message, account: channel.account, inbox: channel.inbox, conversation: conversation, message_type: :outgoing)
      end
      let(:service) { described_class.new(channel: channel) }

      it 'sends to the phone number instead of failing as an unroutable LID' do
        expect(service).to receive(:request)
          .with(:post, "/message/sendText/#{channel.instance_name}", body: hash_including(number: phone_digits))
          .and_return({ 'key' => { 'id' => 'provider-message-id' } })

        expect(service.send_message(message)).to eq('provider-message-id')
      end

      it 'uses the phone JID for quoted replies, edits and deletes' do
        expect(service.send(:resolved_remote_jid_for, message)).to eq("#{phone_digits}@s.whatsapp.net")

        message.update!(source_id: 'provider-message-id')
        expect(service).to receive(:request)
          .with(
            :delete,
            "/chat/deleteMessageForEveryone/#{channel.instance_name}",
            body: hash_including(remoteJid: "#{phone_digits}@s.whatsapp.net")
          ).and_return({})

        service.delete_message(message: message)
      end

      it 'prefers the phone identity tied to this LID over other phone identities of the contact' do
        other_contact_inbox = create(:contact_inbox, inbox: channel.inbox, contact: contact, source_id: '77055555555')
        create(:contact_channel_profile, contact_inbox: other_contact_inbox, profile_data: { 'canonical_jid' => '77055555555@s.whatsapp.net' })
        conversation

        expect(service).to receive(:request)
          .with(:post, "/message/sendText/#{channel.instance_name}", body: hash_including(number: phone_digits))
          .and_return({ 'key' => { 'id' => 'provider-message-id' } })

        service.send_message(message)
      end

      it 'falls back to the contact phone number when no other phone identity exists' do
        phone_contact_inbox.channel_profile.destroy!
        phone_contact_inbox.destroy!
        conversation

        expect(service).to receive(:request)
          .with(:post, "/message/sendText/#{channel.instance_name}", body: hash_including(number: phone_digits))
          .and_return({ 'key' => { 'id' => 'provider-message-id' } })

        service.send_message(message)
      end

      it 'leaves a refused send to the phone number as a plain RequestError' do
        allow(service).to receive(:request)
          .with(:post, "/message/sendText/#{channel.instance_name}", body: hash_including(number: phone_digits))
          .and_raise(described_class::RequestError.new('Bad Request', status: 400, body: {}))

        expect { service.send_message(message) }.to raise_error(an_instance_of(described_class::RequestError))
      end

      it 'addresses the @lid JID itself when the contact has no phone identity at all' do
        phone_contact_inbox.channel_profile.destroy!
        phone_contact_inbox.destroy!
        contact.update!(phone_number: nil)
        conversation

        expect(service).to receive(:request)
          .with(:post, "/message/sendText/#{channel.instance_name}", body: hash_including(number: lid_jid))
          .and_return({ 'key' => { 'id' => 'provider-message-id' } })

        service.send_message(message)
      end
    end

    context 'when the contact is known only by a hidden @lid identity' do
      let(:lid_jid) { '143907392331785@lid' }
      let(:contact) do
        create(
          :contact,
          account: channel.account,
          additional_attributes: {
            'lid_jid' => lid_jid,
            'raw_jid' => lid_jid,
            'canonical_jid' => lid_jid,
            'provisional_whatsapp_identity' => true
          }
        )
      end
      let(:contact_inbox) { create(:contact_inbox, inbox: channel.inbox, contact: contact, source_id: lid_jid) }
      let(:conversation) do
        create(:conversation, account: channel.account, inbox: channel.inbox, contact: contact, contact_inbox: contact_inbox)
      end
      let(:message) do
        create(:message, account: channel.account, inbox: channel.inbox, conversation: conversation, message_type: :outgoing)
      end
      let(:quoted_message) do
        create(
          :message,
          account: channel.account,
          inbox: channel.inbox,
          conversation: conversation,
          message_type: :incoming,
          source_id: 'quoted-wa-id'
        )
      end
      let(:service) { described_class.new(channel: channel) }
      let(:send_text_path) { "/message/sendText/#{channel.instance_name}" }

      it 'addresses the text message to the full @lid JID' do
        expect(service).to receive(:request)
          .with(:post, send_text_path, body: hash_including(number: lid_jid))
          .and_return({ 'key' => { 'id' => 'provider-message-id' } })

        expect(service.send_message(message)).to eq('provider-message-id')
      end

      it 'addresses media to the full @lid JID' do
        attachment = message.attachments.new(account_id: message.account_id, file_type: :image)
        attachment.file.attach(io: Rails.root.join('spec/assets/avatar.png').open, filename: 'avatar.png', content_type: 'image/png')
        attachment.save!

        expect(service).to receive(:request)
          .with(:post, "/message/sendMedia/#{channel.instance_name}", body: hash_including(number: lid_jid, mediatype: 'image'))
          .and_return({ 'key' => { 'id' => 'provider-message-id' } })

        expect(service.send_message(message)).to eq('provider-message-id')
      end

      it 'quotes the replied message under the @lid JID' do
        quoted_message
        message.update!(content_attributes: { 'in_reply_to_external_id' => 'quoted-wa-id' })

        expect(service).to receive(:request)
          .with(
            :post,
            send_text_path,
            body: hash_including(number: lid_jid, quoted: { key: { remoteJid: lid_jid, id: 'quoted-wa-id' } })
          ).and_return({ 'key' => { 'id' => 'provider-message-id' } })

        service.send_message(message)
      end

      it 'prefers the conversation own @lid over another @lid kept on the contact' do
        contact.update!(additional_attributes: contact.additional_attributes.merge('canonical_jid' => '999@lid', 'raw_jid' => '999@lid'))

        expect(service).to receive(:request)
          .with(:post, send_text_path, body: hash_including(number: lid_jid))
          .and_return({ 'key' => { 'id' => 'provider-message-id' } })

        service.send_message(message)
      end

      it 'uses the @lid JID for edits, deletes and reactions' do
        message.update!(source_id: 'wa-lid-1')

        expect(service).to receive(:request)
          .with(
            :post,
            "/chat/updateMessage/#{channel.instance_name}",
            body: hash_including(number: lid_jid, key: { id: 'wa-lid-1', fromMe: true, remoteJid: lid_jid })
          ).and_return({})
        service.update_message(message: message, content: 'Edited text')

        expect(service).to receive(:request)
          .with(:delete, "/chat/deleteMessageForEveryone/#{channel.instance_name}", body: { id: 'wa-lid-1', fromMe: true, remoteJid: lid_jid })
          .and_return({})
        service.delete_message(message: message)

        expect(service).to receive(:request)
          .with(
            :post,
            "/message/sendReaction/#{channel.instance_name}",
            body: { key: { remoteJid: lid_jid, fromMe: true, id: 'wa-lid-1' }, reaction: 'ok' }
          ).and_return({})
        service.send_reaction(message: message, emoji: 'ok')
      end

      context 'when the gateway refuses the @lid' do
        let(:refusal_body) do
          { 'status' => 400, 'error' => 'Bad Request', 'response' => { 'message' => [{ 'jid' => lid_jid, 'exists' => false }] } }
        end

        def gateway_error(status)
          described_class::RequestError.new('Bad Request', status: status, body: refusal_body)
        end

        it 'raises a LidRecipientRequestError that keeps the status and the body of the refusal' do
          allow(service).to receive(:request).with(:post, send_text_path, body: hash_including(number: lid_jid)).and_raise(gateway_error(400))

          expect { service.send_message(message) }.to raise_error(described_class::LidRecipientRequestError) do |error|
            expect(error).to be_a(described_class::RequestError)
            expect([error.status, error.body, error.message]).to eq([400, refusal_body, 'Bad Request'])
          end
        end

        it 'tags a refused media message the same way' do
          attachment = message.attachments.new(account_id: message.account_id, file_type: :image)
          attachment.file.attach(io: Rails.root.join('spec/assets/avatar.png').open, filename: 'avatar.png', content_type: 'image/png')
          attachment.save!
          allow(service).to receive(:request).with(:post, "/message/sendMedia/#{channel.instance_name}", body: hash_including(number: lid_jid))
                                             .and_raise(gateway_error(404))

          expect { service.send_message(message) }.to raise_error(described_class::LidRecipientRequestError) do |error|
            expect(error.status).to eq(404)
          end
        end

        it 'does not change what a transient failure means: it stays retryable and keeps its status' do
          allow(service).to receive(:request).and_raise(gateway_error(503))

          expect { service.send_message(message) }.to raise_error(described_class::RequestError) do |error|
            expect([error.status, error.retryable?]).to eq([503, true])
          end
        end

        it 'does not record provider activity for a refused message' do
          allow(service).to receive(:request).and_raise(gateway_error(400))

          expect { service.send_message(message) }.to raise_error(described_class::RequestError)
          expect(channel.reload.last_provider_activity_at).to be_nil
        end
      end

      it 'still reports an unroutable recipient when there is no candidate at all' do
        quoted_message
        message.update!(content_attributes: { 'in_reply_to_external_id' => 'quoted-wa-id' })
        contact_inbox.update_column(:source_id, ' ') # rubocop:disable Rails/SkipsModelValidations
        contact.update!(additional_attributes: {}, phone_number: nil)

        expect(service).not_to receive(:request)
        expect { service.send_message(message) }.to raise_error(described_class::UnroutableRecipientError)
        expect { service.send(:quoted_payload, message) }.to raise_error(described_class::UnroutableRecipientError)
      end
    end

    context 'when the conversation is a group chat or a plain phone chat' do
      let(:service) { described_class.new(channel: channel) }
      let(:send_text_path) { "/message/sendText/#{channel.instance_name}" }

      def message_for(source_id, in_reply_to: nil)
        contact = create(:contact, account: channel.account)
        contact_inbox = create(:contact_inbox, inbox: channel.inbox, contact: contact, source_id: source_id)
        conversation = create(:conversation, account: channel.account, inbox: channel.inbox, contact: contact, contact_inbox: contact_inbox)
        if in_reply_to
          create(:message, account: channel.account, inbox: channel.inbox, conversation: conversation, message_type: :incoming,
                           source_id: in_reply_to)
        end
        create(
          :message,
          account: channel.account,
          inbox: channel.inbox,
          conversation: conversation,
          message_type: :outgoing,
          content_attributes: { 'in_reply_to_external_id' => in_reply_to }.compact
        )
      end

      it 'addresses and quotes a group by its group JID' do
        group_jid = '120363025246125486@g.us'

        expect(service).to receive(:request)
          .with(:post, send_text_path, body: hash_including(number: group_jid, quoted: { key: { remoteJid: group_jid, id: 'quoted-wa-id' } }))
          .and_return({ 'key' => { 'id' => 'provider-message-id' } })

        service.send_message(message_for(group_jid, in_reply_to: 'quoted-wa-id'))
      end

      it 'leaves a refused send to a group or a phone chat as a plain RequestError' do
        allow(service).to receive(:request).and_raise(described_class::RequestError.new('Bad Request', status: 400, body: {}))

        %w[120363025246125486@g.us 15551234567].each do |source_id|
          expect { service.send_message(message_for(source_id)) }.to raise_error(an_instance_of(described_class::RequestError))
        end
      end

      it 'addresses a phone chat by digits and quotes it under the phone JID' do
        expect(service).to receive(:request)
          .with(
            :post,
            send_text_path,
            body: hash_including(number: '15551234567', quoted: { key: { remoteJid: '15551234567@s.whatsapp.net', id: 'quoted-wa-id' } })
          ).and_return({ 'key' => { 'id' => 'provider-message-id' } })

        service.send_message(message_for('15551234567', in_reply_to: 'quoted-wa-id'))
      end
    end
  end
end
