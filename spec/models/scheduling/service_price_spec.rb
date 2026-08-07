require 'rails_helper'

RSpec.describe Scheduling::ServicePrice, type: :model do
  it 'allows an active zero-price link for a free service' do
    service_price = build(:scheduling_service_price, price: 0, active: true)

    expect(service_price).to be_valid
  end

  it 'rejects a negative price' do
    service_price = build(:scheduling_service_price, price: -1, active: true)

    expect(service_price).not_to be_valid
    expect(service_price.errors[:price]).to be_present
  end
end
