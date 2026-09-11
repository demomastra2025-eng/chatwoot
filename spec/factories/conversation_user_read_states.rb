FactoryBot.define do
  factory :conversation_user_read_state do
    account
    conversation
    user
    last_seen_at { Time.current }
  end
end
