require 'rails_helper'

RSpec.describe Crm::Events::PublishJob do
  it 'publishes the persisted event' do
    event = instance_double(Crm::Event)
    allow(Crm::Event).to receive(:find).with(123).and_return(event)
    allow(event).to receive(:publish!)

    described_class.perform_now(123)

    expect(event).to have_received(:publish!)
  end
end
