require 'rails_helper'

RSpec.describe WebhookJob do
  include ActiveJob::TestHelper

  subject(:job) { described_class.perform_later(url, payload, webhook_type) }

  let(:url) { 'https://one-link.kz' }
  let(:payload) { { name: 'test' } }
  let(:webhook_type) { :account_webhook }

  it 'queues the job' do
    expect { job }.to have_enqueued_job(described_class)
      .with(url, payload, webhook_type)
      .on_queue('medium')
  end

  it 'executes perform with default webhook type' do
    expect(Webhooks::Trigger).to receive(:execute).with(url, payload, webhook_type, secret: nil, delivery_id: nil)
    perform_enqueued_jobs { job }
  end

  context 'with custom webhook type' do
    let(:webhook_type) { :api_inbox_webhook }

    it 'executes perform with inbox webhook type' do
      expect(Webhooks::Trigger).to receive(:execute).with(url, payload, webhook_type, secret: nil, delivery_id: nil)
      perform_enqueued_jobs { job }
    end

    it 'retries transient failures and handles failure after retries are exhausted' do
      retryable_error = Webhooks::Trigger::RetryableError.new(status: 500, message: '500 Internal Server Error')
      expect(Webhooks::Trigger).to receive(:execute).with(
        url,
        payload,
        webhook_type,
        secret: 'webhook-secret',
        delivery_id: 'delivery-1'
      ).exactly(5).times.and_raise(retryable_error)
      trigger_instance = instance_double(Webhooks::Trigger, handle_failure: true)
      expect(Webhooks::Trigger).to receive(:new).with(
        url,
        payload,
        webhook_type,
        secret: 'webhook-secret',
        delivery_id: 'delivery-1'
      ).and_return(trigger_instance)

      expect(trigger_instance).to receive(:handle_failure).with(instance_of(Webhooks::Trigger::RetryableError)).once

      perform_enqueued_jobs do
        described_class.perform_later(
          url,
          payload,
          webhook_type,
          secret: 'webhook-secret',
          delivery_id: 'delivery-1'
        )
      end
    end
  end
end
