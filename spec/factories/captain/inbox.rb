FactoryBot.define do
  factory :captain_inbox, class: 'CaptainInbox' do
    association :captain_assistant, factory: :captain_assistant
    association :inbox
    ai_enabled { true }

    after(:create) do |assignment|
      account = assignment.inbox.account
      if assignment.ai_enabled? && assignment.inbox.channel_type != 'Channel::Voice' && account.captain_default_assistant_id.blank?
        account.update!(captain_default_assistant_id: assignment.captain_assistant_id)
      end
    end
  end
end
