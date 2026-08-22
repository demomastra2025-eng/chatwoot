require 'rails_helper'

RSpec.describe Webhooks::WhatsappEventsJob do
  let(:account) { create(:account, limits: { non_web_inboxes: 10 }) }
  let(:channel) do
    create(
      :channel_whatsapp,
      account: account,
      provider: 'whatsapp_cloud',
      sync_templates: false,
      validate_provider_config: false
    )
  end
  let(:process_service) { instance_double(Whatsapp::IncomingMessageWhatsappCloudService, perform: nil) }
  let(:prepared) { instance_double(Whatsapp::CloudMediaDownload, download!: nil, close: nil) }
  let(:params) do
    {
      object: 'whatsapp_business_account',
      phone_number: channel.phone_number,
      entry: [{
        id: channel.provider_config['business_account_id'],
        changes: [{
          field: 'messages',
          value: {
            metadata: {
              phone_number_id: channel.provider_config['phone_number_id'],
              display_phone_number: channel.phone_number.delete_prefix('+')
            },
            contacts: [{ wa_id: '77000000000', profile: { name: 'Customer' } }],
            messages: [{
              id: 'wamid.media-lock-1',
              from: '77000000000',
              type: 'image',
              image: { id: 'media-lock-1', mime_type: 'image/jpeg' }
            }]
          }
        }]
      }]
    }.with_indifferent_access
  end
  let(:verification_context) do
    waba_id = channel.provider_config['business_account_id'].to_s
    {
      hmac_verified: true,
      channel_id: channel.id,
      channel_identity: Whatsapp::AuthenticatedWebhookRoute.identity_snapshot(channel, channel.phone_number),
      waba_account_ids: { waba_id => channel.account_id },
      waba_scoped: false
    }
  end

  it 'downloads outside the WABA lock and persists after reacquiring it' do
    lock_held = false
    lock_calls = 0

    allow(Whatsapp::WabaLivePriority).to receive(:with_waiters).and_yield
    allow(Whatsapp::WabaLock).to receive(:with_locks) do |_waba_ids, &block|
      lock_calls += 1
      lock_held = true
      block.call
    ensure
      lock_held = false
    end
    allow(Whatsapp::CloudMediaDownload).to receive(:prepare) do
      expect(lock_held).to be(true)
      prepared
    end
    allow(prepared).to receive(:download!) do
      expect(lock_held).to be(false)
      prepared
    end
    allow(Whatsapp::IncomingMessageWhatsappCloudService).to receive(:new) do |**options|
      expect(lock_held).to be(true)
      expect(options[:prepared_attachment]).to eq(prepared)
      process_service
    end

    described_class.perform_now(params, verification_context)

    expect(lock_calls).to eq(2)
    expect(process_service).to have_received(:perform).once
    expect(prepared).to have_received(:close)
  end

  it 'keeps a non-media message in the original single locked phase' do
    text_params = params.deep_dup
    message = text_params.dig(:entry, 0, :changes, 0, :value, :messages, 0)
    message[:type] = 'text'
    message[:text] = { body: 'hello' }
    message.delete(:image)
    lock_held = false
    lock_calls = 0

    allow(Whatsapp::WabaLivePriority).to receive(:with_waiters).and_yield
    allow(Whatsapp::WabaLock).to receive(:with_locks) do |_waba_ids, &block|
      lock_calls += 1
      lock_held = true
      block.call
    ensure
      lock_held = false
    end
    allow(Whatsapp::CloudMediaDownload).to receive(:prepare) do
      expect(lock_held).to be(true)
      nil
    end
    allow(Whatsapp::IncomingMessageWhatsappCloudService).to receive(:new) do |**options|
      expect(lock_held).to be(true)
      expect(options).not_to have_key(:prepared_attachment)
      process_service
    end

    described_class.perform_now(text_params, verification_context)

    expect(lock_calls).to eq(1)
    expect(process_service).to have_received(:perform).once
  end

  it 'retries without persistence when credentials rotate during the download' do
    allow(Whatsapp::CloudMediaDownload).to receive(:prepare).and_return(prepared)
    allow(prepared).to receive(:download!) do
      channel.update!(provider_config: channel.provider_config.merge('api_key' => 'rotated-token'))
      prepared
    end
    allow(Whatsapp::IncomingMessageWhatsappCloudService).to receive(:new)

    expect do
      described_class.perform_now(params, verification_context)
    end.to have_enqueued_job(described_class).on_queue('whatsapp_inbound')

    expect(Whatsapp::IncomingMessageWhatsappCloudService).not_to have_received(:new)
    expect(prepared).to have_received(:close)
  end

  it 'retries and closes the tempfile without reacquiring the WABA lock when the binary download fails' do
    lock_calls = 0
    allow(Whatsapp::WabaLivePriority).to receive(:with_waiters).and_yield
    allow(Whatsapp::WabaLock).to receive(:with_locks) do |_waba_ids, &block|
      lock_calls += 1
      block.call
    end
    allow(Whatsapp::CloudMediaDownload).to receive(:prepare).and_return(prepared)
    allow(prepared).to receive(:download!).and_raise(Down::TooManyRedirects)
    allow(Whatsapp::IncomingMessageWhatsappCloudService).to receive(:new)

    expect do
      described_class.perform_now(params, verification_context)
    end.to have_enqueued_job(described_class).on_queue('whatsapp_inbound')

    expect(lock_calls).to eq(1)
    expect(Whatsapp::IncomingMessageWhatsappCloudService).not_to have_received(:new)
    expect(prepared).to have_received(:close)
  end

  it 'retries without dispatch when Meta media metadata cannot be resolved' do
    allow(Whatsapp::WabaLivePriority).to receive(:with_waiters).and_yield
    allow(Whatsapp::WabaLock).to receive(:with_locks).and_yield
    allow(Whatsapp::CloudMediaDownload).to receive(:prepare)
      .and_raise(Whatsapp::CloudMediaDownload::MetadataFetchError, 'metadata unavailable')
    allow(Whatsapp::IncomingMessageWhatsappCloudService).to receive(:new)

    expect do
      described_class.perform_now(params, verification_context)
    end.to have_enqueued_job(described_class).on_queue('whatsapp_inbound')

    expect(Whatsapp::IncomingMessageWhatsappCloudService).not_to have_received(:new)
  end

  it 'keeps account updates in the original single locked phase' do
    account_params = params.deep_dup
    account_params.dig(:entry, 0, :changes, 0)[:field] = 'account_update'
    job = described_class.new
    lock_calls = 0

    allow(Whatsapp::WabaLivePriority).to receive(:with_waiters).and_yield
    allow(Whatsapp::WabaLock).to receive(:with_locks) do |_waba_ids, &block|
      lock_calls += 1
      block.call
    end
    allow(Whatsapp::CloudMediaDownload).to receive(:prepare).and_return(nil)
    allow(job).to receive(:handle_account_updates)

    job.dispatch_authenticated_change(channel, account_params, verification_context)

    expect(lock_calls).to eq(1)
    expect(job).to have_received(:handle_account_updates).with(account_params)
  end

  it 'keeps lifecycle events in the original single locked phase' do
    lifecycle_params = params.deep_dup
    lifecycle_field = Whatsapp::LifecycleWebhookService::FIELDS.first
    lifecycle_params.dig(:entry, 0, :changes, 0)[:field] = lifecycle_field
    job = described_class.new
    lock_calls = 0

    allow(Whatsapp::WabaLivePriority).to receive(:with_waiters).and_yield
    allow(Whatsapp::WabaLock).to receive(:with_locks) do |_waba_ids, &block|
      lock_calls += 1
      block.call
    end
    allow(Whatsapp::CloudMediaDownload).to receive(:prepare).and_return(nil)
    allow(job).to receive(:trusted_lifecycle_update?).and_return(true)
    allow(job).to receive(:handle_lifecycle_updates)

    job.dispatch_authenticated_change(channel, lifecycle_params, verification_context)

    expect(lock_calls).to eq(1)
    expect(job).to have_received(:handle_lifecycle_updates).with(channel, lifecycle_field, lifecycle_params)
  end

  it 'keeps enterprise call events on their dedicated service path' do
    call_params = params.deep_dup
    change = call_params.dig(:entry, 0, :changes, 0)
    call_payload = { id: 'call-1', event: 'connect' }.with_indifferent_access
    change[:field] = 'calls'
    change[:value].delete(:messages)
    change[:value][:calls] = [call_payload]
    change[:value][:contacts] = []
    call_service = instance_double(Whatsapp::IncomingCallService, perform: true)
    job = described_class.new

    allow(Whatsapp::WabaLivePriority).to receive(:with_waiters).and_yield
    allow(Whatsapp::WabaLock).to receive(:with_locks).and_yield
    allow(Whatsapp::CloudMediaDownload).to receive(:prepare).and_return(nil)
    allow(job).to receive(:with_lock).and_yield
    expect(Whatsapp::IncomingWebhookMessageDispatch).not_to receive(:new)
    expect(Whatsapp::IncomingCallService).to receive(:new)
      .with(inbox: channel.inbox, params: { calls: [call_payload], contacts: [] })
      .and_return(call_service)

    job.perform(call_params, verification_context)

    expect(call_service).to have_received(:perform)
  end
end
