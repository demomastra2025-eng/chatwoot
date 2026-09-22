require 'rails_helper'

RSpec.describe AutomationRules::PublishEventJob do
  it 'raises when the queue adapter rejects the wakeup' do
    job = described_class.new(123)
    allow(described_class).to receive(:new).with(123).and_return(job)
    allow(job).to receive(:enqueue).and_return(false)

    expect { described_class.perform_later!(123) }.to raise_error(ActiveJob::EnqueueError, 'Automation event publication was not enqueued')
  end

  it 'delegates claim and publication to the PostgreSQL-backed publisher' do
    publisher = instance_double(AutomationRules::Events::Publisher, perform: true)
    allow(AutomationRules::Events::Publisher).to receive(:new).with(123, reservation_token: nil).and_return(publisher)

    described_class.perform_now(123)

    expect(publisher).to have_received(:perform)
  end

  it 'passes the persisted wakeup reservation to the publisher' do
    publisher = instance_double(AutomationRules::Events::Publisher, perform: true)
    allow(AutomationRules::Events::Publisher).to receive(:new).with(123, reservation_token: 'token').and_return(publisher)

    described_class.perform_now(123, 'token')

    expect(publisher).to have_received(:perform)
  end
end
