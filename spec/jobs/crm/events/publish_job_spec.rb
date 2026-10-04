require 'rails_helper'

RSpec.describe Crm::Events::PublishJob do
  it 'raises an enqueue error rather than losing the job when enqueue returns false' do
    job = described_class.new(123)
    allow(described_class).to receive(:new).with(123).and_return(job)
    allow(job).to receive(:enqueue).and_return(false)

    expect { described_class.perform_later!(123) }.to raise_error(ActiveJob::EnqueueError, 'CRM event publication was not enqueued')
  end

  it 'propagates adapter exceptions to the durable outbox' do
    job = described_class.new(123)
    allow(described_class).to receive(:new).with(123).and_return(job)
    allow(job).to receive(:enqueue).and_raise(StandardError, 'adapter unavailable')

    expect { described_class.perform_later!(123) }.to raise_error(StandardError, 'adapter unavailable')
  end

  it 'publishes the persisted event' do
    event = instance_double(Crm::Event)
    allow(Crm::Event).to receive(:find).with(123).and_return(event)
    allow(event).to receive(:publish!)

    described_class.perform_now(123)

    expect(event).to have_received(:publish!)
  end
end
