FactoryBot.define do
  factory :telephony_number_binding, class: 'Telephony::NumberBinding' do
    account
    inbox { create(:inbox, account: account) }
    provider { 'fonoster' }
    number_ref { SecureRandom.uuid }
    phone_number { inbox.channel.try(:phone_number) || "+1555#{SecureRandom.random_number(10_000_000).to_s.rjust(7, '0')}" }
    app_ref { SecureRandom.uuid }
    trunk_ref { SecureRandom.uuid }
    metadata { {} }
  end
end
