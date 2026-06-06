# frozen_string_literal: true

FactoryBot.define do
  factory :communication_thread do
    status { 'open' }
    priority { nil }
    last_activity_at { Time.current }

    after(:build) do |communication_thread|
      communication_thread.account ||= communication_thread.contact&.account || create(:account)
      communication_thread.contact ||= create(:contact, account: communication_thread.account)
    end
  end

  factory :communication_thread_conversation do
    primary { false }

    after(:build) do |link|
      link.communication_thread ||= create(:communication_thread)
      link.account ||= link.communication_thread.account

      conversation_created_by_factory = link.conversation.blank?
      link.conversation ||= create(:conversation, account: link.account, contact: link.communication_thread.contact)
      link.inbox ||= link.conversation.inbox
      link.contact_inbox ||= link.conversation.contact_inbox

      if conversation_created_by_factory
        CommunicationThreadConversation.where(
          account_id: link.account_id,
          conversation_id: link.conversation_id
        ).delete_all
        link.conversation.association(:communication_thread_conversation).reset
        link.conversation.association(:communication_thread).reset
      end
    end
  end
end
