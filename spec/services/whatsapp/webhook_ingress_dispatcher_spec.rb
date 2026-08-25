require 'rails_helper'

RSpec.describe Whatsapp::WebhookIngressDispatcher do
  let(:payload) do
    {
      object: 'whatsapp_business_account',
      entry: [{
        id: '123456',
        changes: [{ field: 'messages', value: { metadata: { phone_number_id: '987654' } } }]
      }]
    }
  end
  let(:verification_context) { ->(_payload) { { hmac_verified: true } } }

  it 'holds the shared WABA lock through final route resolution and enqueue' do
    dispatch_router = instance_double(Whatsapp::WebhookIngressRouter)
    normalizer = instance_double(Whatsapp::WebhookBatchNormalizer, perform: [payload])
    waba_lock = instance_double(Whatsapp::WabaLock)
    inside_waba_lock = false
    inside_registry_lock = false

    allow(Whatsapp::WebhookIngressRouter).to receive(:new).and_return(dispatch_router)
    allow(Whatsapp::WebhookBatchNormalizer).to receive(:new).and_return(normalizer)
    allow(Whatsapp::WabaLock).to receive(:new).with('123456').and_return(waba_lock)
    allow(waba_lock).to receive(:with_lock) do |&block|
      inside_waba_lock = true
      block.call
    ensure
      inside_waba_lock = false
    end
    allow(WhatsappWebhookRoute).to receive(:with_waba_registry_lock).with('123456') do |&block|
      inside_registry_lock = true
      block.call
    ensure
      inside_registry_lock = false
    end
    allow(dispatch_router).to receive(:destinations) do
      expect(inside_waba_lock).to be(true)
      expect(inside_registry_lock).to be(true)
      ['widget']
    end
    allow(Webhooks::WhatsappForwardJob).to receive(:perform_later) do |job_payload, destination|
      expect(inside_waba_lock).to be(true)
      expect(inside_registry_lock).to be(true)
      expect(job_payload).to eq(payload)
      expect(destination).to eq('widget')
    end

    described_class.new(
      payload: payload,
      central_ingress: true,
      default_callback: true,
      verification_context: verification_context
    ).perform

    expect(Webhooks::WhatsappForwardJob).to have_received(:perform_later).once
  end

  it 'normalizes every central-ingress batch before any route lookup' do
    mixed_payload = payload.deep_dup
    mixed_payload[:entry] << {
      id: '654321',
      changes: [{ field: 'messages', value: { metadata: { phone_number_id: '456789' } } }]
    }
    waba_locks = {
      '123456' => instance_double(Whatsapp::WabaLock),
      '654321' => instance_double(Whatsapp::WabaLock)
    }

    allow(Whatsapp::WabaLock).to receive(:new) { |waba_id| waba_locks.fetch(waba_id) }
    waba_locks.each_value { |lock| allow(lock).to receive(:with_lock).and_yield }
    allow(WhatsappWebhookRoute).to receive(:with_waba_registry_lock).and_yield
    allow(Whatsapp::WebhookIngressRouter).to receive(:new) do |payload:|
      expect(payload.fetch(:entry).size).to eq(1)
      instance_double(Whatsapp::WebhookIngressRouter, destinations: ['prod'])
    end
    allow(Webhooks::WhatsappEventsJob).to receive(:perform_later)

    described_class.new(
      payload: mixed_payload,
      central_ingress: true,
      default_callback: true,
      verification_context: verification_context
    ).perform

    expect(Webhooks::WhatsappEventsJob).to have_received(:perform_later).twice
    expect(WhatsappWebhookRoute).to have_received(:with_waba_registry_lock).with('123456').once
    expect(WhatsappWebhookRoute).to have_received(:with_waba_registry_lock).with('654321').once
  end
end
