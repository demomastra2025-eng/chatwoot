require 'rails_helper'

RSpec.describe Webhooks::WhatsappEventsJob do
  subject(:job) { described_class }

  let(:channel) { create(:channel_whatsapp, provider: 'whatsapp_cloud', sync_templates: false, validate_provider_config: false) }
  let(:params)  do
    {
      object: 'whatsapp_business_account',
      phone_number: channel.phone_number,
      entry: [{
        id: channel.provider_config['business_account_id'],
        changes: [
          {
            value: {
              metadata: {
                phone_number_id: channel.provider_config['phone_number_id'],
                display_phone_number: channel.phone_number.delete('+')
              }
            }
          }
        ]
      }]
    }
  end
  let(:process_service) { double }

  before do
    allow(process_service).to receive(:perform)
  end

  def verified_context(*channels, channel_id: nil)
    verified_channel = channels.find { |item| item.id == channel_id }
    {
      hmac_verified: true,
      channel_id: channel_id,
      channel_identity: verified_channel_identity(verified_channel),
      waba_account_ids: verified_waba_account_ids(channels),
      waba_scoped: channel_id.nil?
    }
  end

  def verified_waba_account_ids(channels)
    channels.group_by { |item| item.provider_config['business_account_id'].to_s }.transform_values do |items|
      account_ids = items.map(&:account_id).uniq
      account_ids.one? ? account_ids.first : nil
    end
  end

  def verified_channel_identity(channel)
    return {} unless channel

    {
      account_id: channel.account_id,
      provider: channel.provider,
      waba_id: channel.provider_config['business_account_id'].to_s,
      phone_number_id: channel.provider_config['phone_number_id'].to_s,
      route_phone: channel.phone_number.to_s
    }
  end

  def enable_coexistence_sync!(target_channel)
    target_channel.update!(
      provider_config: target_channel.provider_config.merge(
        'embedded_signup_flow' => 'coexistence',
        'coexistence_sync' => { 'generation' => 'generation-1' }
      )
    )
  end

  it 'enqueues the job' do
    expect { job.perform_later(params) }.to have_enqueued_job(described_class)
      .with(params)
      .on_queue('whatsapp_inbound')
  end

  it 'keeps retrying WABA lock contention after the previous retry limit' do
    job_instance = described_class.new(params, verified_context(channel, channel_id: channel.id))
    job_instance.executions = 7
    allow(Whatsapp::WabaLock).to receive(:with_locks).and_raise(Whatsapp::WabaLock::LockAcquisitionError)

    expect { job_instance.perform_now }.to have_enqueued_job(described_class).on_queue('whatsapp_inbound')
  end

  it 'retries an out-of-order mutation until its original message arrives' do
    allow_any_instance_of(described_class).to receive(:dispatch_changes)
      .and_raise(Whatsapp::IncomingMessageMutationService::TargetNotFoundError)

    expect { described_class.perform_now(params) }.to have_enqueued_job(described_class).on_queue('whatsapp_inbound')
  end

  context 'when whatsapp_cloud provider' do
    it 'enqueue Whatsapp::IncomingMessageWhatsappCloudService' do
      allow(Whatsapp::IncomingMessageWhatsappCloudService).to receive(:new).and_return(process_service)
      expect(Whatsapp::IncomingMessageWhatsappCloudService).to receive(:new)
      job.perform_now(params, verified_context(channel, channel_id: channel.id))
    end

    it 'dispatches every phone in a signed WABA-scoped batch to its sibling channel' do
      sibling = create(
        :channel_whatsapp,
        account: channel.account,
        provider: 'whatsapp_cloud',
        sync_templates: false,
        validate_provider_config: false
      )
      sibling.update!(provider_config: sibling.provider_config.merge('business_account_id' => channel.provider_config['business_account_id']))
      batched_params = {
        object: 'whatsapp_business_account',
        entry: [channel, sibling].map do |item|
          {
            id: item.provider_config['business_account_id'],
            changes: [{
              field: 'messages',
              value: {
                metadata: {
                  phone_number_id: item.provider_config['phone_number_id'],
                  display_phone_number: item.phone_number.delete_prefix('+')
                }
              }
            }]
          }
        end
      }.with_indifferent_access
      allow(Whatsapp::IncomingMessageWhatsappCloudService).to receive(:new).and_return(process_service)

      job.perform_now(batched_params, verified_context(channel, sibling))

      expect(Whatsapp::IncomingMessageWhatsappCloudService).to have_received(:new)
        .with(inbox: channel.inbox, params: anything).once
      expect(Whatsapp::IncomingMessageWhatsappCloudService).to have_received(:new)
        .with(inbox: sibling.inbox, params: anything).once
    end

    it 'dispatches a legacy signed Cloud job through a runtime-bound routing context' do
      allow(Whatsapp::IncomingMessageWhatsappCloudService).to receive(:new).and_return(process_service)
      allow(Rails.logger).to receive(:warn)

      job.perform_now(params, hmac_verified: true)

      expect(Whatsapp::IncomingMessageWhatsappCloudService).to have_received(:new)
        .with(inbox: channel.inbox, params: params)
      expect(Rails.logger).to have_received(:warn)
        .with('[WHATSAPP_WEBHOOK] processing legacy signed job with runtime-bound routing context')
    end

    it 'fails closed when a legacy explicit callback WABA differs from a standard lifecycle payload WABA' do
      payload_channel = create(
        :channel_whatsapp,
        account: create(:account),
        provider: 'whatsapp_cloud',
        sync_templates: false,
        validate_provider_config: false
      )
      payload_channel.update!(
        provider_config: payload_channel.provider_config.merge('business_account_id' => 'legacy-cross-waba-payload')
      )
      lifecycle_params = {
        object: 'whatsapp_business_account',
        phone_number: channel.phone_number,
        entry: [{
          id: payload_channel.provider_config['business_account_id'],
          changes: [{ field: 'message_template_status_update', value: { event: 'APPROVED' } }]
        }]
      }.with_indifferent_access
      allow(Whatsapp::LifecycleWebhookService).to receive(:new)
      allow(Rails.logger).to receive(:warn)

      job.perform_now(lifecycle_params, hmac_verified: true)

      expect(Whatsapp::LifecycleWebhookService).not_to have_received(:new)
      expect(Rails.logger).to have_received(:warn)
        .with('[WHATSAPP_WEBHOOK] refused payload because explicit callback WABA does not match payload WABA')
    end

    it 'fails closed when a legacy explicit lifecycle payload omits its WABA identity' do
      lifecycle_params = {
        object: 'whatsapp_business_account',
        phone_number: channel.phone_number,
        entry: [{ changes: [{ field: 'message_template_status_update', value: { event: 'APPROVED' } }] }]
      }.with_indifferent_access
      allow(Whatsapp::LifecycleWebhookService).to receive(:new)
      allow(Rails.logger).to receive(:warn)

      job.perform_now(lifecycle_params, hmac_verified: true)

      expect(Whatsapp::LifecycleWebhookService).not_to have_received(:new)
      expect(Rails.logger).to have_received(:warn)
        .with('[WHATSAPP_WEBHOOK] refused payload because explicit callback WABA does not match payload WABA')
    end

    it 'fails closed for a legacy queued Cloud job without verified HMAC' do
      expect(Whatsapp::IncomingMessageWhatsappCloudService).not_to receive(:new)

      job.perform_now(params)
    end

    it 'does not treat a partial signed routing context as a legacy job' do
      allow(Whatsapp::IncomingMessageWhatsappCloudService).to receive(:new)

      job.perform_now(params, hmac_verified: true, channel_id: channel.id)

      expect(Whatsapp::IncomingMessageWhatsappCloudService).not_to have_received(:new)
    end

    it 'fails closed for a legacy signed WABA callback with ambiguous current ownership' do
      waba_id = channel.provider_config['business_account_id']
      sibling = create(
        :channel_whatsapp,
        account: create(:account),
        provider: 'whatsapp_cloud',
        sync_templates: false,
        validate_provider_config: false
      )
      sibling.update!(provider_config: sibling.provider_config.merge('business_account_id' => waba_id))
      waba_params = params.deep_dup
      waba_params.delete(:phone_number)
      waba_params[:entry].first[:id] = waba_id
      allow(Whatsapp::IncomingMessageWhatsappCloudService).to receive(:new)

      job.perform_now(waba_params, hmac_verified: true)

      expect(Whatsapp::IncomingMessageWhatsappCloudService).not_to have_received(:new)
    end

    it 'will not enqueue message jobs based on phone number in the URL if the entry payload is not present' do
      params = {
        object: 'whatsapp_business_account',
        phone_number: channel.phone_number,
        entry: [{ changes: [{}] }]
      }
      allow(Whatsapp::IncomingMessageWhatsappCloudService).to receive(:new)
      allow(Whatsapp::IncomingMessageService).to receive(:new)

      expect(Whatsapp::IncomingMessageWhatsappCloudService).not_to receive(:new)
      expect(Whatsapp::IncomingMessageService).not_to receive(:new)
      job.perform_now(params, verified_context(channel, channel_id: channel.id))
    end

    it 'fails closed when an explicit callback phone conflicts with payload metadata' do
      sibling = create(
        :channel_whatsapp,
        account: channel.account,
        provider: 'whatsapp_cloud',
        sync_templates: false,
        validate_provider_config: false
      )
      sibling.update!(
        provider_config: sibling.provider_config.merge(
          'business_account_id' => channel.provider_config['business_account_id']
        )
      )
      conflicting_params = params.deep_merge(
        entry: [{
          id: channel.provider_config['business_account_id'],
          changes: [{
            field: 'messages',
            value: {
              metadata: {
                phone_number_id: sibling.provider_config['phone_number_id'],
                display_phone_number: sibling.phone_number.delete_prefix('+')
              }
            }
          }]
        }]
      )
      allow(Rails.logger).to receive(:error)

      expect(Whatsapp::IncomingMessageWhatsappCloudService).not_to receive(:new)

      job.perform_now(conflicting_params, verified_context(channel, channel_id: channel.id))

      expect(Rails.logger).to have_received(:error)
        .with('[WHATSAPP_WEBHOOK] refused payload because callback phone conflicts with payload metadata')
    end

    it 'still processes inbound messages when channel reauthorization is required' do
      channel.prompt_reauthorization!
      allow(Whatsapp::IncomingMessageWhatsappCloudService).to receive(:new).and_return(process_service)
      expect(Whatsapp::IncomingMessageWhatsappCloudService).to receive(:new).with(inbox: channel.inbox, params: params)
      job.perform_now(params, verified_context(channel, channel_id: channel.id))
    end

    it 'will not enqueue if channel is not present' do
      allow(Whatsapp::IncomingMessageWhatsappCloudService).to receive(:new).and_return(process_service)
      allow(Whatsapp::IncomingMessageService).to receive(:new).and_return(process_service)

      expect(Whatsapp::IncomingMessageWhatsappCloudService).not_to receive(:new)
      expect(Whatsapp::IncomingMessageService).not_to receive(:new)
      job.perform_now(phone_number: 'random_phone_number')
    end

    it 'will not enqueue Whatsapp::IncomingMessageWhatsappCloudService if account is suspended' do
      account = channel.account
      account.update!(status: :suspended)
      allow(Whatsapp::IncomingMessageWhatsappCloudService).to receive(:new).and_return(process_service)
      allow(Whatsapp::IncomingMessageService).to receive(:new).and_return(process_service)

      expect(Whatsapp::IncomingMessageWhatsappCloudService).not_to receive(:new)
      expect(Whatsapp::IncomingMessageService).not_to receive(:new)
      job.perform_now(params, verified_context(channel, channel_id: channel.id))
    end

    it 'does not dispatch to an inbox pending deletion' do
      channel.inbox.update!(deleting_at: Time.current)
      allow(Whatsapp::IncomingMessageWhatsappCloudService).to receive(:new)

      job.perform_now(params, verified_context(channel, channel_id: channel.id))

      expect(Whatsapp::IncomingMessageWhatsappCloudService).not_to have_received(:new)
    end

    it 'rejects a signed payload when WABA ownership changed after ingress' do
      verification_context = verified_context(channel, channel_id: channel.id)
      signed_params = params.deep_dup
      signed_params[:entry].first[:id] = channel.provider_config['business_account_id']
      channel.update!(account: create(:account))
      allow(Whatsapp::IncomingMessageWhatsappCloudService).to receive(:new)
      allow(Rails.logger).to receive(:warn)

      job.perform_now(signed_params, verification_context)

      expect(Whatsapp::IncomingMessageWhatsappCloudService).not_to have_received(:new)
      expect(Rails.logger).to have_received(:warn)
        .with('[WHATSAPP_WEBHOOK] refused payload because authenticated channel identity changed')
    end

    it 'rejects a signed payload when phone identity changed after ingress' do
      verification_context = verified_context(channel, channel_id: channel.id)
      channel.update!(provider_config: channel.provider_config.merge('phone_number_id' => 'replacement-phone-id'))
      allow(Whatsapp::IncomingMessageWhatsappCloudService).to receive(:new)

      job.perform_now(params, verification_context)

      expect(Whatsapp::IncomingMessageWhatsappCloudService).not_to have_received(:new)
    end

    it 'does not log an inactive warning solely because channel reauthorization is required' do
      channel.prompt_reauthorization!
      allow(Whatsapp::IncomingMessageWhatsappCloudService).to receive(:new).and_return(process_service)
      allow(Rails.logger).to receive(:warn)

      expect(Rails.logger).not_to receive(:warn).with("Inactive WhatsApp channel: #{channel.phone_number}")
      job.perform_now(params, verified_context(channel, channel_id: channel.id))
    end

    it 'logs a warning with unknown phone number when channel does not exist' do
      unknown_phone = '+123****7890'
      allow(Rails.logger).to receive(:warn)

      expect(Rails.logger).to receive(:warn).with("Inactive WhatsApp channel: unknown - #{unknown_phone}")
      job.perform_now(phone_number: unknown_phone)
    end

    it 'dispatches WhatsApp Cloud call events under a stable call lock' do
      call_payload = {
        id: 'wacid.call-1',
        from: '77470000000',
        to: channel.phone_number.delete('+'),
        event: 'connect',
        direction: 'USER_INITIATED',
        session: { sdp: 'v=0', sdp_type: 'offer' }
      }
      call_params = params.deep_merge(
        entry: [{
          changes: [{
            field: 'calls',
            value: {
              metadata: {
                phone_number_id: channel.provider_config['phone_number_id'],
                display_phone_number: channel.phone_number.delete('+')
              },
              calls: [call_payload]
            }
          }]
        }]
      )
      service = instance_double(Whatsapp::IncomingCallService, perform: true)

      expect(Redis::Alfred::WHATSAPP_MESSAGE_MUTEX).to eq('WHATSAPP_MESSAGE_CREATE_LOCK::%<inbox_id>s::%<sender_id>s')
      expect(Whatsapp::IncomingCallService).to receive(:new)
        .with(inbox: channel.inbox, params: { calls: [call_payload.with_indifferent_access], contacts: [] })
        .and_return(service)

      expect do
        job.perform_now(call_params.with_indifferent_access, verified_context(channel, channel_id: channel.id))
      end.not_to raise_error
    end

    it 'dispatches batched calls and call statuses exactly once each' do
      call_params = params.deep_merge(
        entry: [{
          changes: [{
            field: 'calls',
            value: {
              metadata: {
                phone_number_id: channel.provider_config['phone_number_id'],
                display_phone_number: channel.phone_number.delete('+')
              },
              calls: [
                { id: 'wacid.call-1', from: '111' },
                { id: 'wacid.call-2', from: '222' }
              ],
              statuses: [
                { id: 'wacid.call-1', type: 'call', status: 'accepted' },
                { id: 'wacid.call-2', type: 'call', status: 'ended' }
              ]
            }
          }]
        }]
      ).with_indifferent_access
      dispatched = []
      call_service = instance_double(Whatsapp::IncomingCallService, perform: true)
      allow(Whatsapp::IncomingCallService).to receive(:new) do |inbox:, params:|
        expect(inbox).to eq(channel.inbox)
        dispatched << params
        call_service
      end

      job.perform_now(call_params, verified_context(channel, channel_id: channel.id))

      expect(dispatched.flat_map { |payload| Array(payload[:calls]).pluck(:id) }).to eq(%w[wacid.call-1 wacid.call-2])
      expect(dispatched.flat_map { |payload| Array(payload[:statuses]).pluck(:id) }).to eq(%w[wacid.call-1 wacid.call-2])
      expect(dispatched).to have_attributes(size: 4)
    end

    it 'routes signed lifecycle events without passing them to the message parser' do
      lifecycle_params = {
        object: 'whatsapp_business_account',
        phone_number: channel.phone_number,
        entry: [{
          id: channel.provider_config['business_account_id'],
          time: 1_751_247_548,
          changes: [{
            field: 'message_template_status_update',
            value: {
              event: 'APPROVED',
              message_template_id: 1_689_556_908_129_832,
              message_template_name: 'order_confirmation',
              message_template_language: 'en-US'
            }
          }]
        }]
      }.with_indifferent_access
      lifecycle_service = instance_double(Whatsapp::LifecycleWebhookService, perform: :processed)

      expect(Whatsapp::LifecycleWebhookService).to receive(:new)
        .with(channel: channel, field: 'message_template_status_update', params: lifecycle_params)
        .and_return(lifecycle_service)
      expect(Whatsapp::IncomingMessageWhatsappCloudService).not_to receive(:new)

      job.perform_now(lifecycle_params, verified_context(channel, channel_id: channel.id))
    end

    it 'ignores unsigned lifecycle events' do
      lifecycle_params = {
        object: 'whatsapp_business_account',
        phone_number: channel.phone_number,
        entry: [{
          id: channel.provider_config['business_account_id'],
          changes: [{ field: 'security', value: { event: 'PIN_RESET_REQUEST' } }]
        }]
      }.with_indifferent_access
      allow(Whatsapp::LifecycleWebhookService).to receive(:new)

      job.perform_now(lifecycle_params, { hmac_verified: false })

      expect(Whatsapp::LifecycleWebhookService).not_to have_received(:new)
    end

    it 'routes metadata-free account_update events through the signed callback channel' do
      account_update_params = {
        object: 'whatsapp_business_account',
        phone_number: channel.phone_number,
        entry: [{
          id: channel.provider_config['business_account_id'],
          changes: [{ field: 'account_update', value: { event: 'ACCOUNT_OFFBOARDED' } }]
        }]
      }.with_indifferent_access
      account_update_service = instance_double(Whatsapp::AccountUpdateService, perform: true)

      expect(Whatsapp::AccountUpdateService).to receive(:new)
        .with(channel: channel, params: account_update_params)
        .and_return(account_update_service)
      expect(Whatsapp::IncomingMessageWhatsappCloudService).not_to receive(:new)

      job.perform_now(account_update_params, verified_context(channel, channel_id: channel.id))
    end

    it 'keeps a legacy callback phone under WABA-scoped authorization' do
      account_update_params = {
        object: 'whatsapp_business_account',
        phone_number: channel.phone_number,
        entry: [{
          id: channel.provider_config['business_account_id'],
          changes: [{ field: 'account_update', value: { event: 'ACCOUNT_OFFBOARDED' } }]
        }]
      }.with_indifferent_access
      account_update_service = instance_double(Whatsapp::AccountUpdateService, perform: true)

      expect(Whatsapp::AccountUpdateService).to receive(:new)
        .with(channel: channel, params: account_update_params)
        .and_return(account_update_service)

      job.perform_now(account_update_params, verified_context(channel))
    end

    it 'ignores unsigned account_update events even when the callback channel resolves' do
      account_update_params = {
        object: 'whatsapp_business_account',
        phone_number: channel.phone_number,
        entry: [{
          id: channel.provider_config['business_account_id'],
          changes: [{ field: 'account_update', value: { event: 'ACCOUNT_OFFBOARDED' } }]
        }]
      }.with_indifferent_access
      allow(Whatsapp::AccountUpdateService).to receive(:new)

      job.perform_now(account_update_params, { hmac_verified: false })

      expect(Whatsapp::AccountUpdateService).not_to have_received(:new)
    end

    it 'processes messages alongside a signed account_update in the same payload' do
      mixed_params = {
        object: 'whatsapp_business_account',
        phone_number: channel.phone_number,
        entry: [{
          id: channel.provider_config['business_account_id'],
          changes: [
            { field: 'account_update', value: { event: 'ACCOUNT_RECONNECTED' } },
            { field: 'messages', value: { messages: [{ id: 'wamid.1' }] } }
          ]
        }]
      }.with_indifferent_access
      account_update_service = instance_double(Whatsapp::AccountUpdateService, perform: true)
      message_service = instance_double(Whatsapp::IncomingMessageWhatsappCloudService, perform: true)
      allow(Whatsapp::AccountUpdateService).to receive(:new).and_return(account_update_service)
      allow(Whatsapp::IncomingMessageWhatsappCloudService).to receive(:new).and_return(message_service)

      job.perform_now(mixed_params, verified_context(channel, channel_id: channel.id))

      expected_account_update_params = mixed_params.deep_dup
      expected_account_update_params[:entry].first[:changes] = [mixed_params[:entry].first[:changes].first]
      expected_message_params = mixed_params.deep_dup
      expected_message_params[:entry].first[:changes] = [mixed_params[:entry].first[:changes].last]
      expect(Whatsapp::AccountUpdateService).to have_received(:new)
        .with(channel: channel, params: expected_account_update_params).once
      expect(Whatsapp::IncomingMessageWhatsappCloudService).to have_received(:new)
        .with(inbox: channel.inbox, params: expected_message_params).once
    end

    it 'processes every account update from a batched callback independently' do
      second_channel = create(
        :channel_whatsapp,
        account: channel.account,
        provider: 'whatsapp_cloud',
        sync_templates: false,
        validate_provider_config: false
      )
      second_channel.update!(
        provider_config: second_channel.provider_config.merge('business_account_id' => 'second-waba-id')
      )
      batched_params = {
        object: 'whatsapp_business_account',
        entry: [
          {
            id: channel.provider_config['business_account_id'],
            changes: [{ field: 'account_update', value: { event: 'ACCOUNT_RECONNECTED' } }]
          },
          {
            id: second_channel.provider_config['business_account_id'],
            changes: [{ field: 'account_update', value: { event: 'ACCOUNT_OFFBOARDED' } }]
          }
        ]
      }.with_indifferent_access
      account_update_service = instance_double(Whatsapp::AccountUpdateService, perform: true)
      allow(Whatsapp::AccountUpdateService).to receive(:new).and_return(account_update_service)

      job.perform_now(batched_params, verified_context(channel, second_channel))

      expect(Whatsapp::AccountUpdateService).to have_received(:new).twice
      expect(Whatsapp::AccountUpdateService).to have_received(:new)
        .with(channel: channel, params: hash_including(entry: [hash_including(id: channel.provider_config['business_account_id'])]))
      expect(Whatsapp::AccountUpdateService).to have_received(:new)
        .with(channel: second_channel, params: hash_including(entry: [hash_including(id: second_channel.provider_config['business_account_id'])]))
    end

    it 'does not route metadata to a phone channel when the entry WABA does not match it' do
      mismatched_params = {
        object: 'whatsapp_business_account',
        entry: [{
          id: 'unrelated-entry-waba',
          changes: [{
            field: 'messages',
            value: {
              metadata: {
                phone_number_id: channel.provider_config['phone_number_id'],
                display_phone_number: channel.phone_number.delete('+')
              },
              contacts: [{ wa_id: '111' }],
              messages: [{ id: 'wamid.mismatched-waba', from: '111', type: 'text', text: { body: 'ignored' } }]
            }
          }]
        }]
      }.with_indifferent_access

      expect(Whatsapp::IncomingMessageWhatsappCloudService).not_to receive(:new)

      job.perform_now(mismatched_params, verified_context(channel, channel_id: channel.id))
    end

    it 'rejects a fully verified explicit route when the payload omits the WABA identity' do
      missing_waba_params = {
        object: 'whatsapp_business_account',
        phone_number: channel.phone_number,
        entry: [{ changes: [{ field: 'account_update', value: { event: 'ACCOUNT_RECONNECTED' } }] }]
      }.with_indifferent_access
      allow(Whatsapp::AccountUpdateService).to receive(:new)

      job.perform_now(missing_waba_params, verified_context(channel, channel_id: channel.id))

      expect(Whatsapp::AccountUpdateService).not_to have_received(:new)
    end

    it 'rejects a fully verified metadata-free explicit route for another WABA' do
      mismatched_waba_params = {
        object: 'whatsapp_business_account',
        phone_number: channel.phone_number,
        entry: [{
          id: 'different-waba-id',
          changes: [{ field: 'account_update', value: { event: 'ACCOUNT_RECONNECTED' } }]
        }]
      }.with_indifferent_access
      allow(Whatsapp::AccountUpdateService).to receive(:new)

      job.perform_now(mismatched_waba_params, verified_context(channel, channel_id: channel.id))

      expect(Whatsapp::AccountUpdateService).not_to have_received(:new)
    end

    it 'does not fall back to the only WABA channel when phone metadata mismatches' do
      mismatched_params = {
        object: 'whatsapp_business_account',
        entry: [{
          id: channel.provider_config['business_account_id'],
          changes: [{
            field: 'messages',
            value: {
              metadata: {
                phone_number_id: 'different-phone-number-id',
                display_phone_number: channel.phone_number.delete('+')
              },
              contacts: [{ wa_id: '111' }],
              messages: [{ id: 'wamid.mismatched-phone', from: '111', type: 'text', text: { body: 'ignored' } }]
            }
          }]
        }]
      }.with_indifferent_access

      expect(Whatsapp::IncomingMessageWhatsappCloudService).not_to receive(:new)

      job.perform_now(mismatched_params, verified_context(channel, channel_id: channel.id))
    end

    it 'does not route a default provider from metadata without WABA or an explicit callback phone' do
      channel.update!(provider: 'default')
      metadata_only_params = params.deep_dup
      metadata_only_params.delete(:phone_number)
      metadata_only_params[:entry].first.delete(:id)

      expect(Whatsapp::IncomingMessageService).not_to receive(:new)
      expect(Whatsapp::IncomingMessageWhatsappCloudService).not_to receive(:new)

      job.perform_now(metadata_only_params, verified_context(channel, channel_id: channel.id))
    end

    it 'dispatches every message and status from a batched change independently' do
      metadata = {
        phone_number_id: channel.provider_config['phone_number_id'],
        display_phone_number: channel.phone_number.delete('+')
      }
      batched_params = {
        object: 'whatsapp_business_account',
        entry: [{ changes: [{
          field: 'messages',
          value: {
            metadata: metadata,
            contacts: [{ wa_id: '111' }, { wa_id: '222' }],
            messages: [{ id: 'wamid.1', from: '111' }, { id: 'wamid.2', from: '222' }],
            statuses: [
              { id: 'wamid.out.1', status: 'sent', recipient_id: '111' },
              { id: 'wamid.out.2', status: 'delivered', recipient_id: '222' }
            ]
          }
        }] }]
      }.with_indifferent_access
      dispatched_values = []
      message_service = instance_double(Whatsapp::IncomingMessageWhatsappCloudService, perform: true)
      allow(Whatsapp::IncomingMessageWhatsappCloudService).to receive(:new) do |inbox:, params:, **|
        expect(inbox).to eq(channel.inbox)
        dispatched_values << params.dig(:entry, 0, :changes, 0, :value)
        message_service
      end

      job.perform_now(batched_params, verified_context(channel, channel_id: channel.id))

      expect(dispatched_values.flat_map { |value| Array(value[:messages]).pluck(:id) }).to eq(%w[wamid.1 wamid.2])
      expect(dispatched_values.flat_map { |value| Array(value[:statuses]).pluck(:id) }).to eq(%w[wamid.out.1 wamid.out.2])
      expect(dispatched_values.filter_map { |value| value.dig(:contacts, 0, :wa_id) }).to eq(%w[111 222 111 222])
      expect(dispatched_values).to all(satisfy { |value| Array(value[:messages]).size + Array(value[:statuses]).size == 1 })
    end

    it 'does not attach an unrelated contact when the event has an unmatched identity' do
      webhook_params = {
        object: 'whatsapp_business_account',
        entry: [{ changes: [{
          field: 'messages',
          value: {
            metadata: {
              phone_number_id: channel.provider_config['phone_number_id'],
              display_phone_number: channel.phone_number.delete('+')
            },
            contacts: [{ wa_id: '111' }],
            messages: [{ id: 'wamid.unmatched', from: '999' }]
          }
        }] }]
      }.with_indifferent_access
      dispatched_value = nil
      message_service = instance_double(Whatsapp::IncomingMessageWhatsappCloudService, perform: true)
      allow(Whatsapp::IncomingMessageWhatsappCloudService).to receive(:new) do |params:, **|
        dispatched_value = params.dig(:entry, 0, :changes, 0, :value)
        message_service
      end

      job.perform_now(webhook_params, verified_context(channel, channel_id: channel.id))

      expect(dispatched_value[:contacts]).to be_empty
    end

    it 'dispatches every Business App echo from a batched change independently' do
      echo_params = {
        object: 'whatsapp_business_account',
        entry: [{ changes: [{
          field: 'smb_message_echoes',
          value: {
            metadata: {
              phone_number_id: channel.provider_config['phone_number_id'],
              display_phone_number: channel.phone_number.delete('+')
            },
            message_echoes: [{ id: 'wamid.echo.1', to: '111' }, { id: 'wamid.echo.2', to: '222' }]
          }
        }] }]
      }.with_indifferent_access
      dispatched_ids = []
      message_service = instance_double(Whatsapp::IncomingMessageWhatsappCloudService, perform: true)
      allow(Whatsapp::IncomingMessageWhatsappCloudService).to receive(:new) do |inbox:, params:, outgoing_echo:|
        expect(inbox).to eq(channel.inbox)
        expect(outgoing_echo).to be(true)
        dispatched_ids << params.dig(:entry, 0, :changes, 0, :value, :message_echoes, 0, :id)
        message_service
      end

      job.perform_now(echo_params, verified_context(channel, channel_id: channel.id))

      expect(dispatched_ids).to eq(%w[wamid.echo.1 wamid.echo.2])
    end

    it 'routes coexistence history and contact-state changes to their dedicated importers' do
      enable_coexistence_sync!(channel)
      metadata = {
        phone_number_id: channel.provider_config['phone_number_id'],
        display_phone_number: channel.phone_number.delete('+')
      }
      history_value = { metadata: metadata, history: [] }
      contacts_value = { metadata: metadata, state_sync: [] }
      coexistence_params = {
        object: 'whatsapp_business_account',
        entry: [{ id: channel.provider_config['business_account_id'], time: 1_725_000_000, changes: [
          { field: 'history', value: history_value },
          { field: 'smb_app_state_sync', value: contacts_value }
        ] }]
      }.with_indifferent_access
      routing_context = {
        business_account_id: channel.provider_config['business_account_id'],
        sync_generation: 'generation-1',
        provider_event_at: 1_725_000_000,
        metadata: metadata.deep_stringify_keys
      }
      expect(Whatsapp::CoexistenceWebhookSyncJob).to receive(:perform_later)
        .with(channel.id, 'history', history_value.deep_stringify_keys, routing_context)
      expect(Whatsapp::CoexistenceWebhookSyncJob).to receive(:perform_later)
        .with(channel.id, 'smb_app_state_sync', contacts_value.deep_stringify_keys, routing_context)

      job.perform_now(coexistence_params, verified_context(channel, channel_id: channel.id))
    end

    it 'routes each batched history media follow-up independently' do
      enable_coexistence_sync!(channel)
      history_params = {
        object: 'whatsapp_business_account',
        entry: [{ id: channel.provider_config['business_account_id'], changes: [{
          field: 'history',
          value: {
            metadata: {
              phone_number_id: channel.provider_config['phone_number_id'],
              display_phone_number: channel.phone_number.delete('+')
            },
            messages: [
              { id: 'wamid.history-media.1', from: '111', type: 'image', image: { id: 'media.1' } },
              { id: 'wamid.history-media.2', from: '222', type: 'video', video: { id: 'media.2' } }
            ]
          }
        }] }]
      }.with_indifferent_access
      dispatched_values = []
      allow(Whatsapp::CoexistenceWebhookSyncJob).to receive(:perform_later) do |channel_id, field, value, context|
        expect(channel_id).to eq(channel.id)
        expect(field).to eq('history')
        expect(context).to eq(
          business_account_id: channel.provider_config['business_account_id'],
          sync_generation: 'generation-1',
          metadata: history_params.dig(:entry, 0, :changes, 0, :value, :metadata).to_h
        )
        dispatched_values << value.with_indifferent_access
      end

      job.perform_now(history_params, verified_context(channel, channel_id: channel.id))

      expect(dispatched_values.flat_map { |value| Array(value[:messages]).pluck(:id) })
        .to eq(%w[wamid.history-media.1 wamid.history-media.2])
      expect(dispatched_values).to all(satisfy { |value| Array(value[:messages]).one? })
    end

    it 'routes a WABA-level history change without phone metadata' do
      enable_coexistence_sync!(channel)
      history_value = { history: [] }
      coexistence_params = {
        object: 'whatsapp_business_account',
        entry: [{
          id: channel.provider_config['business_account_id'],
          changes: [{ field: 'history', value: history_value }]
        }]
      }.with_indifferent_access

      expect(Whatsapp::CoexistenceWebhookSyncJob).to receive(:perform_later)
        .with(
          channel.id,
          'history',
          history_value.deep_stringify_keys,
          { business_account_id: channel.provider_config['business_account_id'], sync_generation: 'generation-1', metadata: {} }
        )

      job.perform_now(coexistence_params, verified_context(channel, channel_id: channel.id))
    end

    it 'routes metadata-free history from a standard handoff callback to its coexistence sibling' do
      enable_coexistence_sync!(channel)
      standard_sibling = create(
        :channel_whatsapp,
        account: channel.account,
        provider: 'whatsapp_cloud',
        sync_templates: false,
        validate_provider_config: false
      )
      standard_sibling.update!(
        provider_config: standard_sibling.provider_config.merge(
          'business_account_id' => channel.provider_config['business_account_id'],
          'embedded_signup_flow' => 'standard'
        )
      )
      history_value = { history: [] }
      coexistence_params = {
        object: 'whatsapp_business_account',
        phone_number: standard_sibling.phone_number,
        entry: [{
          id: channel.provider_config['business_account_id'],
          changes: [{ field: 'history', value: history_value }]
        }]
      }.with_indifferent_access

      expect(Whatsapp::CoexistenceWebhookSyncJob).to receive(:perform_later)
        .with(
          channel.id,
          'history',
          history_value.deep_stringify_keys,
          { business_account_id: channel.provider_config['business_account_id'], sync_generation: 'generation-1', metadata: {} }
        )

      job.perform_now(coexistence_params, verified_context(standard_sibling, channel_id: standard_sibling.id))
    end

    it 'ignores a stale cross-account WABA claim when routing an active coexistence owner' do
      enable_coexistence_sync!(channel)
      stale_channel = create(
        :channel_whatsapp,
        provider: 'whatsapp_cloud',
        sync_templates: false,
        validate_provider_config: false
      )
      stale_channel.update!(
        provider_config: stale_channel.provider_config.merge(
          'business_account_id' => channel.provider_config['business_account_id'],
          'embedded_signup_flow' => 'standard'
        )
      )
      stale_channel.account.update!(status: :suspended)
      history_value = { history: [] }
      coexistence_params = {
        object: 'whatsapp_business_account',
        entry: [{
          id: channel.provider_config['business_account_id'],
          changes: [{ field: 'history', value: history_value }]
        }]
      }.with_indifferent_access

      expect(Whatsapp::CoexistenceWebhookSyncJob).to receive(:perform_later)
        .with(
          channel.id,
          'history',
          history_value.deep_stringify_keys,
          { business_account_id: channel.provider_config['business_account_id'], sync_generation: 'generation-1', metadata: {} }
        )

      job.perform_now(coexistence_params, verified_context(channel, channel_id: channel.id))
    end

    it 'fails closed for a metadata-free WABA history change with sibling phones' do
      channel.update!(provider_config: channel.provider_config.merge('embedded_signup_flow' => 'coexistence'))
      sibling = create(
        :channel_whatsapp,
        account: channel.account,
        provider: 'whatsapp_cloud',
        sync_templates: false,
        validate_provider_config: false
      )
      sibling.update!(
        provider_config: sibling.provider_config.merge(
          'business_account_id' => channel.provider_config['business_account_id'],
          'embedded_signup_flow' => 'coexistence'
        )
      )
      history_value = { history: [] }
      coexistence_params = {
        object: 'whatsapp_business_account',
        entry: [{
          id: channel.provider_config['business_account_id'],
          changes: [{ field: 'history', value: history_value }]
        }]
      }.with_indifferent_access

      expect(Whatsapp::CoexistenceWebhookSyncJob).not_to receive(:perform_later)

      job.perform_now(coexistence_params, verified_context(channel, channel_id: channel.id))
    end

    it 'fails closed for metadata-free history when a standard sibling belongs to another account' do
      channel.update!(provider_config: channel.provider_config.merge('embedded_signup_flow' => 'coexistence'))
      standard_sibling = create(
        :channel_whatsapp,
        provider: 'whatsapp_cloud',
        sync_templates: false,
        validate_provider_config: false
      )
      standard_sibling.update!(
        provider_config: standard_sibling.provider_config.merge(
          'business_account_id' => channel.provider_config['business_account_id'],
          'embedded_signup_flow' => 'standard'
        )
      )
      coexistence_params = {
        object: 'whatsapp_business_account',
        entry: [{
          id: channel.provider_config['business_account_id'],
          changes: [{ field: 'history', value: { history: [] } }]
        }]
      }.with_indifferent_access

      expect(Whatsapp::CoexistenceWebhookSyncJob).not_to receive(:perform_later)

      job.perform_now(coexistence_params, verified_context(channel, channel_id: channel.id))
    end

    it 'fails closed for metadata-free history while a cross-account sibling is pending deletion' do
      channel.update!(provider_config: channel.provider_config.merge('embedded_signup_flow' => 'coexistence'))
      pending_sibling = create(
        :channel_whatsapp,
        provider: 'whatsapp_cloud',
        sync_templates: false,
        validate_provider_config: false
      )
      pending_sibling.update!(
        provider_config: pending_sibling.provider_config.merge(
          'business_account_id' => channel.provider_config['business_account_id'],
          'embedded_signup_flow' => 'standard'
        )
      )
      pending_sibling.inbox.update!(deleting_at: Time.current)
      coexistence_params = {
        object: 'whatsapp_business_account',
        entry: [{
          id: channel.provider_config['business_account_id'],
          changes: [{ field: 'history', value: { history: [] } }]
        }]
      }.with_indifferent_access

      expect(Whatsapp::CoexistenceWebhookSyncJob).not_to receive(:perform_later)

      job.perform_now(
        coexistence_params,
        {
          hmac_verified: true,
          channel_id: nil,
          channel_identity: {},
          waba_account_ids: { channel.provider_config['business_account_id'] => nil },
          waba_scoped: true
        }
      )
    end

    it 'fans signed WABA-level account updates out within the owning account' do
      same_account_channel = create(
        :channel_whatsapp,
        account: channel.account,
        provider: 'whatsapp_cloud',
        sync_templates: false,
        validate_provider_config: false
      )
      same_account_channel.update!(
        provider_config: same_account_channel.provider_config.merge(
          'business_account_id' => channel.provider_config['business_account_id']
        )
      )
      account_update_params = {
        object: 'whatsapp_business_account',
        phone_number: channel.phone_number,
        entry: [{
          id: channel.provider_config['business_account_id'],
          changes: [{ field: 'account_update', value: { event: 'ACCOUNT_OFFBOARDED' } }]
        }]
      }.with_indifferent_access
      account_update_service = instance_double(Whatsapp::AccountUpdateService, perform: true)
      allow(Whatsapp::AccountUpdateService).to receive(:new).and_return(account_update_service)

      job.perform_now(account_update_params, verified_context(channel, same_account_channel, channel_id: channel.id))

      expect(Whatsapp::AccountUpdateService).to have_received(:new).with(channel: channel, params: account_update_params).once
      expect(Whatsapp::AccountUpdateService).to have_received(:new).with(channel: same_account_channel, params: account_update_params).once
    end

    it 'rejects a signed account update when WABA ownership spans multiple accounts' do
      other_account_channel = create(
        :channel_whatsapp,
        provider: 'whatsapp_cloud',
        sync_templates: false,
        validate_provider_config: false
      )
      other_account_channel.update!(
        provider_config: other_account_channel.provider_config.merge(
          'business_account_id' => channel.provider_config['business_account_id']
        )
      )
      account_update_params = {
        object: 'whatsapp_business_account',
        entry: [{
          id: channel.provider_config['business_account_id'],
          changes: [{ field: 'account_update', value: { event: 'ACCOUNT_OFFBOARDED' } }]
        }]
      }.with_indifferent_access
      account_update_service = instance_double(Whatsapp::AccountUpdateService, perform: true)
      allow(Whatsapp::AccountUpdateService).to receive(:new).and_return(account_update_service)
      allow(Rails.logger).to receive(:warn)

      job.perform_now(
        account_update_params,
        { hmac_verified: true, channel_id: nil, waba_account_ids: { channel.provider_config['business_account_id'] => nil } }
      )

      expect(Whatsapp::AccountUpdateService).not_to have_received(:new)
      expect(Rails.logger).to have_received(:warn)
        .with('[WHATSAPP_WEBHOOK] refused payload because authenticated WABA ownership changed')
    end

    it 'fails closed for message changes when WABA ownership spans multiple accounts' do
      other_account_channel = create(:channel_whatsapp, provider: 'whatsapp_cloud', sync_templates: false, validate_provider_config: false)
      other_account_channel.update!(
        provider_config: other_account_channel.provider_config.merge(
          'business_account_id' => channel.provider_config['business_account_id']
        )
      )
      metadata = {
        phone_number_id: channel.provider_config['phone_number_id'],
        display_phone_number: channel.phone_number.delete('+')
      }
      mixed_params = {
        object: 'whatsapp_business_account',
        entry: [{
          id: channel.provider_config['business_account_id'],
          changes: [
            { field: 'account_update', value: { event: 'ACCOUNT_RECONNECTED' } },
            { field: 'messages', value: { metadata: metadata, messages: [{ id: 'wamid.mixed' }] } }
          ]
        }]
      }.with_indifferent_access
      message_service = instance_double(Whatsapp::IncomingMessageWhatsappCloudService, perform: true)
      allow(Whatsapp::AccountUpdateService).to receive(:new)
      allow(Whatsapp::IncomingMessageWhatsappCloudService).to receive(:new).and_return(message_service)
      allow(Rails.logger).to receive(:error)

      job.perform_now(
        mixed_params,
        { hmac_verified: true, channel_id: nil, waba_account_ids: { channel.provider_config['business_account_id'] => nil } }
      )

      expect(Whatsapp::AccountUpdateService).not_to have_received(:new)
      expect(Whatsapp::IncomingMessageWhatsappCloudService).not_to have_received(:new)
    end

    it 'does not enqueue coexistence imports for a standard Cloud channel' do
      metadata = {
        phone_number_id: channel.provider_config['phone_number_id'],
        display_phone_number: channel.phone_number.delete('+')
      }
      standard_params = {
        object: 'whatsapp_business_account',
        entry: [{ changes: [{ field: 'history', value: { metadata: metadata, history: [] } }] }]
      }.with_indifferent_access

      expect(Whatsapp::CoexistenceWebhookSyncJob).not_to receive(:perform_later)

      job.perform_now(standard_params, verified_context(channel))
    end
  end

  context 'when default provider' do
    it 'enqueue Whatsapp::IncomingMessageService' do
      stub_request(:post, 'https://waba.360dialog.io/v1/configs/webhook')
      channel.update(provider: 'default')
      allow(Whatsapp::IncomingMessageService).to receive(:new).and_return(process_service)
      expect(Whatsapp::IncomingMessageService).to receive(:new)
      job.perform_now(params)
    end
  end

  context 'when whatsapp business params' do
    it 'routes a default callback based on the number in payload' do
      other_channel = create(:channel_whatsapp, phone_number: '+1987654', provider: 'whatsapp_cloud', sync_templates: false,
                                                validate_provider_config: false)
      wb_params = {
        object: 'whatsapp_business_account',
        entry: [
          {
            changes: [
              {
                value: {
                  metadata: {
                    phone_number_id: other_channel.provider_config['phone_number_id'],
                    display_phone_number: other_channel.phone_number.delete('+')
                  }
                }
              }
            ]
          }
        ]
      }
      allow(Whatsapp::IncomingMessageWhatsappCloudService).to receive(:new).and_return(process_service)
      expect(Whatsapp::IncomingMessageWhatsappCloudService).to receive(:new).with(inbox: other_channel.inbox, params: wb_params)
      job.perform_now(wb_params, verified_context(other_channel, channel_id: other_channel.id))
    end

    it 'Ignore reaction type message and stop raising error' do
      other_channel = create(:channel_whatsapp, phone_number: '+1987654', provider: 'whatsapp_cloud', sync_templates: false,
                                                validate_provider_config: false)
      wb_params = {
        phone_number: channel.phone_number,
        object: 'whatsapp_business_account',
        entry: [{
          changes: [{
            value: {
              contacts: [{ profile: { name: 'Test Test' }, wa_id: '1111981136571' }],
              messages: [{
                from: '1111981136571', reaction: { emoji: '👍' }, timestamp: '1664799904', type: 'reaction'
              }],
              metadata: {
                phone_number_id: other_channel.provider_config['phone_number_id'],
                display_phone_number: other_channel.phone_number.delete('+')
              }
            }
          }]
        }]
      }.with_indifferent_access
      expect do
        Whatsapp::IncomingMessageWhatsappCloudService.new(inbox: other_channel.inbox, params: wb_params).perform
      end.not_to change(Message, :count)
    end

    it 'ignore reaction type message, would not create contact if the reaction is the first event' do
      other_channel = create(:channel_whatsapp, phone_number: '+1987654', provider: 'whatsapp_cloud', sync_templates: false,
                                                validate_provider_config: false)
      wb_params = {
        phone_number: channel.phone_number,
        object: 'whatsapp_business_account',
        entry: [{
          changes: [{
            value: {
              contacts: [{ profile: { name: 'Test Test' }, wa_id: '1111981136571' }],
              messages: [{
                from: '1111981136571', reaction: { emoji: '👍' }, timestamp: '1664799904', type: 'reaction'
              }],
              metadata: {
                phone_number_id: other_channel.provider_config['phone_number_id'],
                display_phone_number: other_channel.phone_number.delete('+')
              }
            }
          }]
        }]
      }.with_indifferent_access
      expect do
        Whatsapp::IncomingMessageWhatsappCloudService.new(inbox: other_channel.inbox, params: wb_params).perform
      end.not_to change(Contact, :count)
    end

    it 'ignore request_welcome type message, would not create contact or conversation' do
      other_channel = create(:channel_whatsapp, phone_number: '+1987654', provider: 'whatsapp_cloud', sync_templates: false,
                                                validate_provider_config: false)
      wb_params = {
        phone_number: channel.phone_number,
        object: 'whatsapp_business_account',
        entry: [{
          changes: [{
            value: {
              messages: [{
                from: '1111981136571', timestamp: '1664799904', type: 'request_welcome'
              }],
              metadata: {
                phone_number_id: other_channel.provider_config['phone_number_id'],
                display_phone_number: other_channel.phone_number.delete('+')
              }
            }
          }]
        }]
      }.with_indifferent_access
      expect do
        Whatsapp::IncomingMessageWhatsappCloudService.new(inbox: other_channel.inbox, params: wb_params).perform
      end.not_to change(Contact, :count)

      expect do
        Whatsapp::IncomingMessageWhatsappCloudService.new(inbox: other_channel.inbox, params: wb_params).perform
      end.not_to change(Conversation, :count)
    end

    it 'will not enque Whatsapp::IncomingMessageWhatsappCloudService when invalid phone number id' do
      other_channel = create(:channel_whatsapp, phone_number: '+1987654', provider: 'whatsapp_cloud', sync_templates: false,
                                                validate_provider_config: false)
      wb_params = {
        phone_number: channel.phone_number,
        object: 'whatsapp_business_account',
        entry: [
          {
            changes: [
              {
                value: {
                  metadata: {
                    phone_number_id: 'random phone number id',
                    display_phone_number: other_channel.phone_number.delete('+')
                  }
                }
              }
            ]
          }
        ]
      }
      allow(Whatsapp::IncomingMessageWhatsappCloudService).to receive(:new).and_return(process_service)
      expect(Whatsapp::IncomingMessageWhatsappCloudService).not_to receive(:new).with(inbox: other_channel.inbox, params: wb_params)
      job.perform_now(wb_params, verified_context(other_channel, channel_id: other_channel.id))
    end
  end
end
