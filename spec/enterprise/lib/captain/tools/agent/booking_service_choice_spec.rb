require 'rails_helper'

RSpec.describe Captain::Tools::Agent::BookingServiceChoice do
  let(:account) { create(:account) }
  let(:resource) { create(:scheduling_resource, account: account) }

  def choice(resource_id: resource.id)
    described_class.new(account: account, resource_id: resource_id)
  end

  def offer(service, price: 20_000, active: true, on: resource)
    create(:scheduling_service_price, account: account, service: service, resource: on, price: price, active: active)
  end

  it 'books without a service when the specialist offers none' do
    create(:scheduling_service, account: account)

    expect(choice.perform).to be_nil
  end

  it 'takes the one service the specialist offers' do
    service = create(:scheduling_service, account: account)
    offer(service)
    other = create(:scheduling_resource, account: account)
    offer(create(:scheduling_service, account: account), on: other)

    expect(choice.perform).to eq(service)
  end

  it 'counts a service the calendar can price: the price of the link, else the base price of the service' do
    linked = create(:scheduling_service, account: account, base_price: 0)
    base_priced = create(:scheduling_service, account: account, base_price: 15_000)
    unpriced = create(:scheduling_service, account: account, base_price: 0)
    offer(linked)
    offer(base_priced, price: 0)
    offer(unpriced, price: 0)

    expect { choice.perform }.to raise_error(Scheduling::Error) { |error|
      expect(error.details[:services].pluck(:id)).to contain_exactly(linked.id, base_priced.id)
    }
  end

  it 'leaves out an inactive service and an inactive link' do
    inactive_service = create(:scheduling_service, account: account, active: false)
    inactive_link = create(:scheduling_service, account: account)
    kept = create(:scheduling_service, account: account)
    offer(inactive_service)
    offer(inactive_link, active: false)
    offer(kept)

    expect(choice.perform).to eq(kept)
  end

  it 'answers with the services by ID and name, sorted by name, when the specialist offers several' do
    second = create(:scheduling_service, account: account, name: 'Second visit')
    first = create(:scheduling_service, account: account, name: 'First visit')
    offer(second)
    offer(first)

    expect { choice.perform }.to raise_error(Scheduling::Error) { |error|
      expect(error).to have_attributes(code: 'SERVICE_REQUIRED', status: 422)
      expect(error.details).to eq(mutation_executed: false,
                                  services: [{ id: first.id, name: 'First visit' }, { id: second.id, name: 'Second visit' }])
    }
  end

  it 'lists at most ten services and says how many more there are' do
    Array.new(12) { |index| create(:scheduling_service, account: account, name: format('Service %02d', index)) }.each { |service| offer(service) }

    expect { choice.perform }.to raise_error(Scheduling::Error) { |error|
      expect(error.details[:services].size).to eq(described_class::MAX_LISTED)
      expect(error.details[:services].first[:name]).to eq('Service 00')
      expect(error.details[:more]).to eq(2)
    }
  end
end
