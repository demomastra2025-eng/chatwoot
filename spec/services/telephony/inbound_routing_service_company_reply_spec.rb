require 'rails_helper'

RSpec.describe Telephony::InboundRoutingService do
  let(:service) { described_class.allocate }
  let(:inbox) { instance_double(Inbox, out_of_office?: false, workspace_out_of_office_message: 'Company offline') }
  let(:policy) { instance_double(Telephony::RoutingPolicy, fallback_message: 'Routing fallback') }

  before do
    allow(service).to receive(:inbox).and_return(inbox)
    allow(service).to receive(:routing_policy).and_return(policy)
  end

  it 'does not announce closure during the company working hours' do
    expect(service.send(:reject_message, prefer_out_of_office_message: true)).to eq('Routing fallback')
  end

  it 'uses the common closure message outside hours when it is preferred' do
    allow(inbox).to receive(:out_of_office?).and_return(true)
    expect(service.send(:reject_message, prefer_out_of_office_message: true)).to eq('Company offline')
  end

  it 'preserves the routing fallback priority otherwise' do
    allow(inbox).to receive(:out_of_office?).and_return(true)
    expect(service.send(:reject_message)).to eq('Routing fallback')
  end

  it 'keeps a disabled common reply out of a call rejection' do
    allow(inbox).to receive(:out_of_office?).and_return(true)
    allow(inbox).to receive(:workspace_out_of_office_message).and_return(nil)
    allow(policy).to receive(:fallback_message).and_return(nil)
    expect(service.send(:reject_message, prefer_out_of_office_message: true)).to eq(described_class::DEFAULT_REJECT_MESSAGE)
  end
end
