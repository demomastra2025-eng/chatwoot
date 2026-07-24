# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Channel::WhatsappWeb do
  around do |example|
    with_modified_env(
      'EVOLUTION_API_URL' => 'https://evolution.example.com',
      'EVOLUTION_API_KEY' => 'test-api-key',
      'FRONTEND_URL' => 'https://app.example.com'
    ) do
      example.run
    end
  end

  describe 'callbacks and derived attributes' do
    it 'normalizes the phone number and enqueues provisioning' do
      account = create(:account)

      expect do
        create(:channel_whatsapp_web, account: account, phone_number: '7 (706) 631-8623', skip_provisioning: false)
      end.to have_enqueued_job(Channels::WhatsappWeb::ProvisionJob)

      channel = described_class.last
      expect(channel.generated_inbox_name).to eq('77066318623')
      expect(channel.phone_number).to eq('+77066318623')
      expect(channel.instance_name).to eq("onelink-waweb-#{channel.account_id}_#{channel.generated_inbox_name}")
      expect(channel.webhook_identifier).to be_present
      expect(channel.webhook_secret).to be_present
      expect(channel.webhook_callback_url).to eq("https://app.example.com/webhooks/whatsapp_web/#{channel.webhook_identifier}")
    end

    it 'releases a stuck deleting channel instance name so the same number can be recreated' do
      account = create(:account)
      phone_number = '+77066318623'
      old_channel = create(:channel_whatsapp_web, account: account, phone_number: phone_number)
      old_instance_name = old_channel.instance_name
      old_channel.inbox.mark_pending_deletion!

      new_channel = create(:channel_whatsapp_web, account: account, phone_number: phone_number)

      expect(new_channel.instance_name).to eq(old_instance_name)
      expect(old_channel.reload.instance_name).to eq("#{old_instance_name}--deleted-#{old_channel.id}")
      expect(old_channel.inbox.reload).to be_deleting
    end
  end

  describe 'runtime validation' do
    it 'requires Evolution runtime configuration' do
      with_modified_env('EVOLUTION_API_URL' => nil, 'EVOLUTION_API_KEY' => nil, 'FRONTEND_URL' => nil) do
        channel = described_class.new(
          account: create(:account),
          phone_number: '+77066318623',
          provider_config: {}
        )

        expect(channel).not_to be_valid
        expect(channel.errors.full_messages).to include('EVOLUTION_API_URL must be configured')
        expect(channel.errors.full_messages).to include('EVOLUTION_API_KEY must be configured')
        expect(channel.errors.full_messages).to include('FRONTEND_URL must be configured')
      end
    end
  end

  describe 'provider lifecycle operations' do
    it 'routes reconnect through the shared lifecycle lock' do
      channel = create(:channel_whatsapp_web)
      provider = instance_double(WhatsappWeb::Providers::EvolutionService, reconnect!: channel)
      lifecycle_lock = instance_double(WhatsappWeb::LifecycleLock)

      allow(channel).to receive(:provider_service).and_return(provider)
      allow(WhatsappWeb::LifecycleLock).to receive(:new).with(channel_id: channel.id).and_return(lifecycle_lock)
      expect(lifecycle_lock).to receive(:with_lock).and_yield

      expect(channel.reconnect!).to eq(channel)
    end

    it 'keeps status sync and QR recovery in the same lifecycle lock' do
      channel = create(:channel_whatsapp_web)
      provider = instance_double(WhatsappWeb::Providers::EvolutionService)
      lifecycle_lock = instance_double(WhatsappWeb::LifecycleLock)

      allow(channel).to receive(:provider_service).and_return(provider)
      allow(WhatsappWeb::LifecycleLock).to receive(:new).with(channel_id: channel.id).and_return(lifecycle_lock)
      expect(lifecycle_lock).to receive(:with_lock).once.and_yield
      expect(provider).to receive(:sync_connection_state!) do
        channel.update!(lifecycle_state: 'waiting_for_qr', connection_state: 'connecting')
      end
      expect(provider).to receive(:refresh_qr!).with(artifact_type: 'qr')

      channel.sync_connection_state!(refresh_qr: true, artifact_type: 'qr')
    end

    it 'does not refresh QR after an authoritative runtime event supersedes the poll result' do
      channel = create(:channel_whatsapp_web)
      provider = instance_double(WhatsappWeb::Providers::EvolutionService)
      lifecycle_lock = instance_double(WhatsappWeb::LifecycleLock)
      polled_at = '2026-07-24T20:00:00Z'
      disconnected_at = '2026-07-24T20:00:01Z'

      allow(channel).to receive(:provider_service).and_return(provider)
      allow(WhatsappWeb::LifecycleLock).to receive(:new).with(channel_id: channel.id).and_return(lifecycle_lock)
      allow(lifecycle_lock).to receive(:with_lock).and_yield
      allow(provider).to receive(:sync_connection_state!) do
        channel.update!(
          lifecycle_state: 'waiting_for_qr',
          connection_state: 'connecting',
          sync_state: channel.sync_state_payload.merge('last_runtime_event_at' => polled_at)
        )
      end
      allow(channel).to receive(:with_lock) do |&block|
        described_class.where(id: channel.id).update_all(
          lifecycle_state: 'disconnected',
          connection_state: 'close',
          sync_state: channel.sync_state_payload.merge('last_runtime_event_at' => disconnected_at)
        )
        block.call
      end

      expect(provider).not_to receive(:refresh_qr!)

      channel.sync_connection_state!(refresh_qr: true, artifact_type: 'qr')

      expect(channel.reload.lifecycle_state).to eq('disconnected')
      expect(channel.connection_state).to eq('close')
    end

    it 'does not swallow lifecycle lock contention during provider teardown' do
      channel = create(:channel_whatsapp_web)
      lifecycle_lock = instance_double(WhatsappWeb::LifecycleLock)
      allow(WhatsappWeb::LifecycleLock).to receive(:new).with(channel_id: channel.id).and_return(lifecycle_lock)
      allow(lifecycle_lock).to receive(:with_lock)
        .and_raise(WhatsappWeb::LifecycleLock::LockAcquisitionError, 'already in progress')

      expect { channel.teardown_provider_instance! }
        .to raise_error(WhatsappWeb::LifecycleLock::LockAcquisitionError)
    end
  end

  describe 'runtime identity updates' do
    it 'does not allow changing the phone number after creation' do
      channel = create(:channel_whatsapp_web)

      expect(channel.update(phone_number: '+15550001111')).to be(false)
      expect(channel.errors[:phone_number]).to include('cannot be changed after the inbox is created')
      expect(channel.reload.phone_number).not_to eq('+15550001111')
    end

    it 'does not allow changing provider_config after creation' do
      channel = create(:channel_whatsapp_web)

      expect(channel.update(provider_config: { 'service_user' => { 'email' => 'ops@example.com' } })).to be(false)
      expect(channel.errors[:provider_config]).to include('cannot be changed after the inbox is created')
      expect(channel.reload.provider_config).to eq({})
    end

    it 'allows changing native operator settings after creation' do
      channel = create(:channel_whatsapp_web)

      expect(
        channel.update(
          conversation_pending: true,
          history_lookback_days: 30,
          ignore_jids: %w[111@s.whatsapp.net 222@s.whatsapp.net],
          sign_messages: true,
          sign_delimiter: '\\n---\\n',
          import_contacts: false,
          import_messages: false,
          sync_labels: false
        )
      ).to be(true)

      channel.reload
      expect(channel.conversation_pending).to be(true)
      expect(channel.history_lookback_days).to eq(30)
      expect(channel.ignore_jids).to eq(%w[111@s.whatsapp.net 222@s.whatsapp.net])
      expect(channel.sign_messages).to be(true)
      expect(channel.formatted_sign_delimiter).to eq("\n---\n")
      expect(channel.import_contacts).to be(false)
      expect(channel.import_messages).to be(false)
      expect(channel.sync_labels).to be(false)
    end

    it 'treats zero lookback days as unlimited history' do
      channel = create(:channel_whatsapp_web)

      expect(channel.update(history_lookback_days: 0)).to be(true)
      expect(channel.reload.history_unlimited?).to be(true)
      expect(channel.history_lookback_window).to be_nil
    end
  end

  describe '#evolution_state_payload' do
    it 'includes sync state details for diagnostics' do
      channel = create(:channel_whatsapp_web)

      channel.record_history_sync!(message_count: 12, contact_count: 3, error: nil)

      payload = channel.reload.evolution_state_payload

      expect(payload['history_synced_at']).to be_present
      expect(payload['last_history_message_count']).to eq(12)
      expect(payload['last_history_contact_count']).to eq(3)
    end

    it 'exposes pending history sync and qr lifecycle markers' do
      channel = create(:channel_whatsapp_web)

      freeze_time do
        channel.update!(
          sync_state: channel.sync_state_payload.merge(
            'history_sync_requested_at' => Time.current.iso8601,
            'last_history_sync_mode' => 'full',
            'qr_generated_at' => 30.seconds.ago.iso8601
          )
        )

        payload = channel.reload.evolution_state_payload

        expect(payload['history_sync_requested_at']).to be_present
        expect(payload['history_sync_in_progress']).to be(true)
        expect(payload['last_history_sync_mode']).to eq('full')
        expect(payload['qr_generated_at']).to be_present
      end
    end

    it 'returns a user-safe error message instead of raw Evolution JSON' do
      channel = create(:channel_whatsapp_web)
      channel.update!(
        last_error: {
          status: 400,
          error: 'Bad Request',
          message: ["The \"#{channel.instance_name}\" instance is being deleted"]
        }.to_json
      )

      payload = channel.reload.evolution_state_payload

      expect(payload['last_error']).to eq(described_class::INSTANCE_BEING_DELETED_MESSAGE)
      expect(payload['last_error']).not_to include(channel.instance_name)
      expect(payload['last_error']).not_to include('{')
    end
  end

  describe '.human_readable_error_message' do
    it 'extracts array messages from provider JSON and maps deleting-instance errors' do
      raw_error = {
        status: 400,
        error: 'Bad Request',
        message: ['The "onelink-waweb-1_77066318623" instance is being deleted']
      }.to_json

      expect(described_class.human_readable_error_message(raw_error)).to eq(
        described_class::INSTANCE_BEING_DELETED_MESSAGE
      )
    end
  end

  describe '#request_history_sync!' do
    it 'keeps a pending history sync deduplicated until it finishes' do
      channel = create(:channel_whatsapp_web)

      freeze_time do
        expect do
          channel.request_history_sync!('full')
        end.to have_enqueued_job(Channels::WhatsappWeb::HistorySyncJob).with(
          channel.id,
          'full',
          hash_including('requested_at' => Time.current.iso8601)
        )

        clear_enqueued_jobs

        expect(channel.request_history_sync!('full')).to be(false)
        expect(enqueued_jobs).to be_empty

        travel 3.minutes

        expect(channel.request_history_sync!('full')).to be(false)
        expect(enqueued_jobs).to be_empty
      end
    end

    it 'supersedes a pending request when a newer provider snapshot arrives' do
      channel = create(:channel_whatsapp_web)

      freeze_time do
        first_snapshot = 2.minutes.ago
        newer_snapshot = Time.current

        expect do
          channel.request_history_sync!(
            'full',
            expected_provider_history_synced_at: first_snapshot
          )
        end.to have_enqueued_job(Channels::WhatsappWeb::HistorySyncJob).with(
          channel.id,
          'full',
          hash_including(
            'requested_at' => Time.current.iso8601,
            'expected_provider_history_synced_at' => first_snapshot.iso8601
          )
        )

        clear_enqueued_jobs
        travel 5.seconds

        expect do
          channel.request_history_sync!(
            'full',
            expected_provider_history_synced_at: newer_snapshot
          )
        end.to have_enqueued_job(Channels::WhatsappWeb::HistorySyncJob).with(
          channel.id,
          'full',
          hash_including(
            'requested_at' => Time.current.iso8601,
            'expected_provider_history_synced_at' => newer_snapshot.iso8601
          )
        )

        expect(channel.reload.history_sync_expected_provider_synced_at).to be_within(1.second).of(newer_snapshot)
      end
    end

    it 'allows a stale pending request to recover after the stale timeout passes' do
      channel = create(:channel_whatsapp_web)

      freeze_time do
        channel.request_history_sync!('full')
        clear_enqueued_jobs

        travel 31.minutes

        expect do
          channel.request_history_sync!('full')
        end.to have_enqueued_job(Channels::WhatsappWeb::HistorySyncJob).with(
          channel.id,
          'full',
          hash_including('requested_at' => Time.current.iso8601)
        )
      end
    end
  end

  describe '#history_sync_in_progress?' do
    it 'clears the in-progress marker after a successful incremental sync' do
      channel = create(:channel_whatsapp_web)

      freeze_time do
        channel.update!(
          sync_state: channel.sync_state_payload.merge(
            'history_sync_requested_at' => 1.minute.ago.iso8601,
            'last_history_sync_mode' => 'incremental'
          )
        )

        expect(channel.history_sync_in_progress?).to be(true)

        channel.record_incremental_sync!(message_count: 5, error: nil)

        channel.reload
        expect(channel.history_sync_in_progress?).to be(false)
        expect(channel.last_incremental_sync_at).to be_within(1.second).of(Time.current)
      end
    end

    it 'does not promote a failed full sync into a completed local baseline' do
      channel = create(:channel_whatsapp_web)

      freeze_time do
        channel.update!(
          sync_state: channel.sync_state_payload.merge(
            'history_sync_requested_at' => 1.minute.ago.iso8601,
            'last_history_sync_mode' => 'full'
          )
        )

        channel.record_history_sync!(message_count: 0, contact_count: 0, error: 'timeout')

        channel.reload
        expect(channel.history_synced_at).to be_nil
        expect(channel.history_sync_in_progress?).to be(false)
        expect(channel.evolution_state_payload['last_history_sync_error']).to eq('timeout')
      end
    end

    it 'keeps a newer provider snapshot request pending after an older sync finishes' do
      channel = create(:channel_whatsapp_web)
      stale_channel = described_class.find(channel.id)

      freeze_time do
        older_snapshot = 2.minutes.ago.change(usec: 0)
        newer_snapshot = 30.seconds.ago.change(usec: 0)

        channel.update!(
          sync_state: channel.sync_state_payload.merge(
            'history_sync_requested_at' => 20.seconds.ago.iso8601,
            'history_sync_expected_provider_synced_at' => newer_snapshot.iso8601,
            'provider_history_synced_at' => newer_snapshot.iso8601
          )
        )

        stale_channel.record_history_sync!(
          message_count: 62,
          contact_count: 15,
          error: nil,
          fulfilled_provider_history_synced_at: older_snapshot,
          sync_context: {
            requested_at: 2.minutes.ago.iso8601,
            expected_provider_history_synced_at: older_snapshot.iso8601
          }
        )

        channel.reload
        expect(channel.provider_history_synced_at).to be_within(1.second).of(newer_snapshot)
        expect(channel.local_history_provider_synced_at).to be_within(1.second).of(older_snapshot)
        expect(channel.history_sync_expected_provider_synced_at).to be_within(1.second).of(newer_snapshot)
        expect(channel.history_sync_request_pending?).to be(true)
        expect(channel.history_sync_in_progress?).to be(true)
      end
    end
  end

  describe '#full_history_baseline_present?' do
    it 'treats an empty local inbox as missing the full history baseline even if the sync state says otherwise' do
      channel = create(:channel_whatsapp_web)

      channel.update!(
        sync_state: channel.sync_state_payload.merge(
          'history_synced_at' => 1.hour.ago.iso8601
        )
      )

      expect(channel.full_history_baseline_present?).to be(false)
    end

    it 'treats a local full sync as stale when the provider snapshot is newer' do
      channel = create(:channel_whatsapp_web)
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
        source_id: 'history-msg-1',
        content_attributes: { imported_history: true, external_created_at: 2.hours.ago.iso8601 }
      )

      channel.update!(
        sync_state: channel.sync_state_payload.merge(
          'history_synced_at' => 1.hour.ago.iso8601,
          'last_local_history_sync_finished_at' => 1.hour.ago.iso8601,
          'last_history_sync_mode' => 'full',
          'last_history_message_count' => 1,
          'last_history_contact_count' => 1,
          'provider_history_synced_at' => Time.current.iso8601,
          'provider_history_message_count' => 1448
        )
      )

      expect(channel.full_history_baseline_present?).to be(true)
      expect(channel.full_history_baseline_current?).to be(false)
    end
  end

  describe '#preferred_history_sync_mode' do
    it 'uses a full sync until a local full baseline exists' do
      channel = create(:channel_whatsapp_web)

      expect(channel.preferred_history_sync_mode).to eq('full')
    end

    it 'uses incremental syncs once a local full baseline exists' do
      channel = create(:channel_whatsapp_web)
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
        source_id: 'history-msg-1',
        content_attributes: { imported_history: true }
      )

      channel.update!(
        sync_state: channel.sync_state_payload.merge(
          'history_synced_at' => 1.hour.ago.iso8601,
          'last_local_history_sync_finished_at' => 1.hour.ago.iso8601,
          'last_history_sync_mode' => 'full',
          'last_history_message_count' => 1,
          'last_history_contact_count' => 1
        )
      )

      expect(channel.preferred_history_sync_mode).to eq('incremental')
    end

    it 'falls back to a full sync when a newer provider history snapshot makes the baseline stale' do
      channel = create(:channel_whatsapp_web)
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
        source_id: 'history-msg-1',
        content_attributes: { imported_history: true }
      )

      older_snapshot = 30.minutes.ago.change(usec: 0)
      newer_snapshot = 5.minutes.ago.change(usec: 0)

      channel.update!(
        sync_state: channel.sync_state_payload.merge(
          'history_synced_at' => older_snapshot.iso8601,
          'last_local_history_sync_finished_at' => older_snapshot.iso8601,
          'last_history_sync_mode' => 'full',
          'last_history_message_count' => 1,
          'last_history_contact_count' => 1,
          'provider_history_synced_at' => newer_snapshot.iso8601,
          'local_history_provider_synced_at' => older_snapshot.iso8601,
          'provider_history_message_count' => 1448
        )
      )

      expect(channel.preferred_history_sync_mode).to eq('full')
    end
  end

  describe '#record_provider_history_snapshot!' do
    it 'keeps provider progress separate from the local import baseline' do
      channel = create(:channel_whatsapp_web)

      freeze_time do
        channel.record_provider_history_snapshot!(message_count: 1448, contact_count: 1019)

        channel.reload
        expect(channel.history_synced_at).to be_nil
        expect(channel.provider_history_synced_at).to be_within(1.second).of(Time.current)
        expect(channel.evolution_state_payload['provider_history_message_count']).to eq(1448)
        expect(channel.evolution_state_payload['provider_history_contact_count']).to eq(1019)
        expect(channel.evolution_state_payload['history_sync_expected_provider_synced_at']).to be_nil
      end
    end
  end

  describe '#record_history_sync!' do
    it 'does not overwrite a newer provider snapshot with stale in-memory state' do
      channel = create(:channel_whatsapp_web)
      stale_channel = described_class.find(channel.id)

      freeze_time do
        older_snapshot = 2.minutes.ago.change(usec: 0)
        newer_snapshot = 1.minute.ago.change(usec: 0)

        channel.update!(
          sync_state: channel.sync_state_payload.merge(
            'provider_history_synced_at' => newer_snapshot.iso8601,
            'history_sync_requested_at' => 30.seconds.ago.iso8601,
            'history_sync_expected_provider_synced_at' => newer_snapshot.iso8601
          )
        )

        stale_channel.record_history_sync!(
          message_count: 10,
          contact_count: 2,
          error: nil,
          fulfilled_provider_history_synced_at: older_snapshot,
          sync_context: {
            requested_at: 3.minutes.ago.iso8601,
            expected_provider_history_synced_at: older_snapshot.iso8601
          }
        )

        channel.reload
        expect(channel.provider_history_synced_at).to be_within(1.second).of(newer_snapshot)
        expect(channel.local_history_provider_synced_at).to be_within(1.second).of(older_snapshot)
        expect(channel.history_sync_expected_provider_synced_at).to be_within(1.second).of(newer_snapshot)
      end
    end
  end

  describe '#record_echo_status_miss!' do
    it 'tracks messages.update misses for diagnostics' do
      channel = create(:channel_whatsapp_web)

      freeze_time do
        channel.record_echo_status_miss!(source_id: 'WA-STATUS-1')

        channel.reload
        expect(channel.evolution_state_payload['echo_status_miss_count']).to eq(1)
        expect(channel.evolution_state_payload['last_echo_status_miss_source_id']).to eq('WA-STATUS-1')
        expect(channel.evolution_state_payload['last_echo_status_miss_at']).to be_present
      end
    end
  end

  describe '#ignored_remote_jid?' do
    it 'combines default and custom ignored jids' do
      channel = create(:channel_whatsapp_web, ignore_jids: ['15550001111@s.whatsapp.net'])

      expect(channel.ignored_remote_jid?('status@broadcast')).to be(true)
      expect(channel.ignored_remote_jid?('15550001111@s.whatsapp.net')).to be(true)
      expect(channel.ignored_remote_jid?('15550002222@s.whatsapp.net')).to be(false)
    end
  end
end
