FactoryBot.define do
  factory :telephony_number_binding, class: 'Telephony::NumberBinding' do
    account
    inbox { create(:inbox, account: account) }
    provider { 'sipuni' }
    number_ref { SecureRandom.uuid }
    phone_number { inbox.channel.try(:phone_number) || "+1555#{SecureRandom.random_number(10_000_000).to_s.rjust(7, '0')}" }
    display_phone_number { inbox.channel.try(:phone_number) || phone_number }
    ingress_number { phone_number }
    fonoster_tel_url { nil }
    app_ref { nil }
    trunk_ref { nil }
    metadata { {} }
  end
end
