require 'rails_helper'

RSpec.describe Webhooks::WhatsappEventsJob do
  subject(:job) { described_class }

  let(:channel) { create(:channel_whatsapp, provider: 'whatsapp_cloud', sync_templates: false, validate_provider_config: false) }
  let(:params)  do
    {
      object: 'whatsapp_business_account',
      phone_number: channel.phone_number,
      entry: [{
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

  it 'enqueues the job' do
    expect { job.perform_later(params) }.to have_enqueued_job(described_class)
      .with(params)
      .on_queue('whatsapp_inbound')
  end

  context 'when whatsapp_cloud provider' do
    it 'enqueue Whatsapp::IncomingMessageWhatsappCloudService' do
      allow(Whatsapp::IncomingMessageWhatsappCloudService).to receive(:new).and_return(process_service)
      expect(Whatsapp::IncomingMessageWhatsappCloudService).to receive(:new)
      job.perform_now(params)
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
      job.perform_now(params)
    end

    it 'still processes inbound messages when channel reauthorization is required' do
      channel.prompt_reauthorization!
      allow(Whatsapp::IncomingMessageWhatsappCloudService).to receive(:new).and_return(process_service)
      expect(Whatsapp::IncomingMessageWhatsappCloudService).to receive(:new).with(inbox: channel.inbox, params: params)
      job.perform_now(params)
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
      job.perform_now(params)
    end

    it 'does not log an inactive warning solely because channel reauthorization is required' do
      channel.prompt_reauthorization!
      allow(Whatsapp::IncomingMessageWhatsappCloudService).to receive(:new).and_return(process_service)
      allow(Rails.logger).to receive(:warn)

      expect(Rails.logger).not_to receive(:warn).with("Inactive WhatsApp channel: #{channel.phone_number}")
      job.perform_now(params)
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

      expect { job.perform_now(call_params.with_indifferent_access) }.not_to raise_error
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

      job.perform_now(account_update_params, { hmac_verified: true })
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

      job.perform_now(mixed_params, { hmac_verified: true })

      expected_message_params = mixed_params.deep_dup
      expected_message_params[:entry].first[:changes] = [mixed_params[:entry].first[:changes].last]
      expect(Whatsapp::AccountUpdateService).to have_received(:new).with(channel: channel, params: mixed_params).once
      expect(Whatsapp::IncomingMessageWhatsappCloudService).to have_received(:new)
        .with(inbox: channel.inbox, params: expected_message_params).once
    end

    it 'fans WABA-level account updates out only to matching channels in the callback account' do
      same_account_channel = create(
        :channel_whatsapp,
        account: channel.account,
        provider: 'whatsapp_cloud',
        sync_templates: false,
        validate_provider_config: false
      )
      other_account_channel = create(
        :channel_whatsapp,
        provider: 'whatsapp_cloud',
        sync_templates: false,
        validate_provider_config: false
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

      job.perform_now(account_update_params, { hmac_verified: true })

      expect(Whatsapp::AccountUpdateService).to have_received(:new).with(channel: channel, params: account_update_params).once
      expect(Whatsapp::AccountUpdateService).to have_received(:new).with(channel: same_account_channel, params: account_update_params).once
      expect(Whatsapp::AccountUpdateService).not_to have_received(:new).with(channel: other_account_channel, params: account_update_params)
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
    it 'enqueue Whatsapp::IncomingMessageWhatsappCloudService based on the number in payload' do
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
      job.perform_now(wb_params)
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
      job.perform_now(wb_params)
    end
  end
end
