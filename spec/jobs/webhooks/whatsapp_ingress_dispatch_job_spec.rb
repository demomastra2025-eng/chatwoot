require 'rails_helper'

RSpec.describe Webhooks::WhatsappIngressDispatchJob do
  let(:payload) do
    {
      object: 'whatsapp_business_account',
      entry: [{ id: '123456', changes: [{ field: 'messages', value: {} }] }]
    }
  end
  let(:verification_context) do
    {
      hmac_verified: true,
      waba_account_ids: { '123456' => 1 },
      waba_scoped: true
    }
  end

  it 'uses the inbound queue' do
    expect(described_class.queue_name).to eq('whatsapp_inbound')
  end

  it 'fails closed when the adapter does not confirm enqueue' do
    enqueue_error = ActiveJob::EnqueueError.new('redis unavailable')
    failed_job = instance_double(described_class, successfully_enqueued?: false, enqueue_error: enqueue_error)
    allow(described_class).to receive(:perform_later).and_return(failed_job)

    expect do
      described_class.perform_later!(payload, true, true, verification_context)
    end.to raise_error(enqueue_error)
  end

  it 'dispatches the already-normalized payload with its verified request context' do
    dispatcher = instance_double(Whatsapp::WebhookIngressDispatcher, perform_normalized: true)

    expect(Whatsapp::WebhookIngressDispatcher).to receive(:new) do |payload:, central_ingress:, default_callback:, verification_context:|
      expect(payload).to eq(self.payload)
      expect(central_ingress).to be(true)
      expect(default_callback).to be(true)
      expect(verification_context.call(payload)).to eq(self.verification_context.with_indifferent_access)
      dispatcher
    end

    described_class.perform_now(payload, true, true, verification_context)

    expect(dispatcher).to have_received(:perform_normalized)
  end

  it 're-enqueues lock contention without exhausting a fixed attempt limit' do
    dispatcher = instance_double(Whatsapp::WebhookIngressDispatcher)
    allow(Whatsapp::WebhookIngressDispatcher).to receive(:new).and_return(dispatcher)
    allow(dispatcher).to receive(:perform_normalized).and_raise(Whatsapp::WabaLock::LockAcquisitionError)

    expect do
      described_class.perform_now(payload, true, true, verification_context)
    end.to have_enqueued_job(described_class).with(payload, true, true, verification_context).on_queue('whatsapp_inbound')
  end
end
