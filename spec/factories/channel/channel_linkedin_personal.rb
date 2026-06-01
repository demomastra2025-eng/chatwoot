FactoryBot.define do
  factory :channel_linkedin_personal, class: 'Channel::LinkedinPersonal' do
    account
    sequence(:profile_urn) { |n| "urn:li:fsd_profile:LINKEDIN#{n}" }
    display_name { 'LinkedIn User' }
    li_at { SecureRandom.hex(32) }
    jsessionid { "ajax:#{SecureRandom.hex(8)}" }
    connection_state { 'disconnected' }
    lifecycle_state { 'pending_auth' }
    runtime_state { {} }

    after(:create) do |channel|
      create(:inbox, channel: channel, account: channel.account)
    end
  end
end
