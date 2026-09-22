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

  factory :communication_thread_participant do
    after(:build) do |participant|
      participant.communication_thread ||= create(:communication_thread)
      participant.account ||= participant.communication_thread.account
      participant.user ||= create(:user, account: participant.account)
    end
  end

  factory :communication_thread_participant_lifecycle_fact do
    participant_type { 'User' }
    actor_kind { 'system' }
    actor_type { 'System' }
    actor_id { nil }
    action { 'add' }
    reason { 'manual_add' }
    occurred_at { Time.current }
    reliable_since { occurred_at }
    correlation_id { SecureRandom.uuid }
    sequence(:idempotency_key) { |number| "participant-fact-#{number}" }
    schema_version { 1 }

    after(:build) do |fact|
      fact.communication_thread ||= create(:communication_thread)
      fact.account ||= fact.communication_thread.account
      fact.participant_id ||= create(:user, account: fact.account).id
    end
  end

  factory :communication_thread_manual_call_occurrence do
    actor_type { 'User' }
    actor_name { actor&.name || 'Manual caller' }
    source_kind { 'telephony_call_session' }
    occurred_at { source&.started_at || Time.current }
    reliable_since { occurred_at }
    schema_version { 1 }
    created_at { occurred_at }

    transient do
      actor { nil }
      source { nil }
    end

    after(:build) do |occurrence, evaluator|
      occurrence.communication_thread ||= create(:communication_thread)
      occurrence.account ||= occurrence.communication_thread.account
      actor = evaluator.actor || create(:user, account: occurrence.account)
      occurrence.actor_id ||= actor.id
      source = evaluator.source || create(
        :telephony_call_session,
        :native_manual,
        account: occurrence.account,
        conversation: create(:conversation, account: occurrence.account),
        initiator: actor,
        direction: 'outbound',
        started_at: occurrence.occurred_at
      )
      occurrence.source_id ||= source.id
      occurrence.source_ref ||= source.external_call_ref
    end
  end
end
