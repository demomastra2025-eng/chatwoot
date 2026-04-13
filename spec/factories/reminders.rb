FactoryBot.define do
  factory :reminder do
    account
    creator { create(:user, account: account, role: :administrator) }
    owner { creator }
    action_type { 'send_message' }
    content_kind { 'free_text' }
    text_mode { 'static' }
    timing_mode { 'absolute' }
    repeat_mode { 'once' }
    repeat_until_at { nil }
    status { 'pending' }
    timezone { 'UTC' }
    scheduled_at { 1.hour.from_now }
    body { 'Hello there' }
    attachments { [] }
    template_params { {} }
    metadata { {} }

    transient do
      touch_conversation { nil }
    end

    after(:build) do |reminder, evaluator|
      conversation = evaluator.touch_conversation || reminder.conversation || create(:conversation, account: reminder.account)

      reminder.remindable ||= conversation
      reminder.conversation ||= conversation
      reminder.target_conversation ||= conversation
      reminder.target_inbox ||= conversation.inbox
      reminder.target_contact ||= conversation.contact
      reminder.target_contact_inbox ||= conversation.contact_inbox
    end

    trait :draft do
      status { 'draft' }
    end

    trait :relative do
      timing_mode { 'relative' }
      relative_anchor { 'conversation.created_at' }
      relative_offset_seconds { 3600 }
      scheduled_at { nil }
    end
  end
end
