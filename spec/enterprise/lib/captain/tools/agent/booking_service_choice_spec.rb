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

    expect(choice.perform).to be_nil
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

  it 'leaves the service unset when the specialist offers several' do
    second = create(:scheduling_service, account: account, name: 'Second visit')
    first = create(:scheduling_service, account: account, name: 'First visit')
    offer(second)
    offer(first)

    expect(choice.perform).to be_nil
  end

  it 'leaves the service unset when more than ten are offered' do
    Array.new(12) { |index| create(:scheduling_service, account: account, name: format('Service %02d', index)) }.each { |service| offer(service) }

    expect(choice.perform).to be_nil
  end
end
