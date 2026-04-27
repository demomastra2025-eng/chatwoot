# frozen_string_literal: true

FactoryBot.define do
  factory :call do
    account
    provider { :whatsapp }
    direction { :incoming }
    status { 'ringing' }
    sequence(:provider_call_id) { |n| "wamid-call-#{n}" }
    sequence(:media_session_id) { |n| "media-session-#{n}" }

    after(:build) do |call|
      call.inbox ||= begin
        channel = create(
          :channel_whatsapp,
          account: call.account,
          provider: 'whatsapp_cloud',
          provider_config: { 'calling_enabled' => true, 'media_server_enabled' => true },
          sync_templates: false,
          validate_provider_config: false
        )
        channel.inbox
      end
      call.contact ||= create(:contact, :with_phone_number, account: call.account)
      call.conversation ||= create(:conversation, account: call.account, inbox: call.inbox, contact: call.contact)
    end
  end
end
