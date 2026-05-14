FactoryBot.define do
  factory :kaspi_pay_payment, class: 'KaspiPay::Payment' do
    integration_hook { association :integrations_hook, :kaspi_pay }
    account { integration_hook.account }
    source do
      resource = association(:scheduling_resource, account: integration_hook.account)
      contact = association(:contact, account: integration_hook.account)
      service = association(:scheduling_service, account: integration_hook.account)
      association(:scheduling_appointment, account: integration_hook.account, resource: resource, contact: contact, service: service)
    end
    payment_type { 'qr' }
    amount { 10_000 }
    currency { 'KZT' }
    status { 'pending' }
    idempotency_key { SecureRandom.uuid }
  end
end
