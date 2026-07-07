FactoryBot.define do
  factory :telephony_call_session, class: 'Telephony::CallSession' do
    account
    conversation { create(:conversation, account: account) }
    contact { conversation.contact }
    inbox { conversation.inbox }
    number_binding { create(:telephony_number_binding, account: account, inbox: inbox) }
    provider { 'sipuni' }
    external_call_ref { SecureRandom.uuid }
    status { 'ringing' }
    direction { 'outbound' }
    from_number { inbox.channel.try(:phone_number) || '+15551230000' }
    to_number { contact.phone_number || '+15551239999' }
    metadata { {} }
  end
end
