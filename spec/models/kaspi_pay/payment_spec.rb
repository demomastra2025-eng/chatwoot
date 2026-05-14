require 'rails_helper'

RSpec.describe KaspiPay::Payment do
  let(:account) { create(:account) }
  let(:hook) { create(:integrations_hook, :kaspi_pay, account: account) }
  let(:resource) { create(:scheduling_resource, account: account) }
  let(:contact) { create(:contact, account: account) }
  let(:service) { create(:scheduling_service, account: account) }
  let(:appointment) { create(:scheduling_appointment, account: account, resource: resource, contact: contact, service: service) }

  it 'syncs account from the integration hook' do
    payment = described_class.new(
      integration_hook: hook,
      source: appointment,
      payment_type: 'qr',
      amount: 10_000,
      status: 'pending'
    )

    payment.validate

    expect(payment.account_id).to eq(account.id)
  end

  it 'accepts only supported payment types and statuses' do
    payment = described_class.new(
      account: account,
      integration_hook: hook,
      source: appointment,
      payment_type: 'card',
      amount: 10_000,
      status: 'unknown'
    )

    expect(payment).not_to be_valid
    expect(payment.errors[:payment_type]).to be_present
    expect(payment.errors[:status]).to be_present
  end

  it 'identifies final statuses' do
    expect(build(:kaspi_pay_payment, status: 'paid')).to be_final_status
    expect(build(:kaspi_pay_payment, status: 'expired')).to be_final_status
    expect(build(:kaspi_pay_payment, status: 'failed')).to be_final_status
    expect(build(:kaspi_pay_payment, status: 'pending')).not_to be_final_status
  end
end
