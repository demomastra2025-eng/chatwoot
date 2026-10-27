FactoryBot.define do
  # A text channel row holds the channel settings only (it names no agent). A voice number names its voice agent.
  factory :captain_inbox, class: 'CaptainInbox' do
    association :inbox
    ai_enabled { true }
    captain_assistant { association(:captain_assistant, account: inbox.account) if inbox.channel_type == 'Channel::Voice' }
  end
end
