# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Reminder, type: :model do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:entry) { create(:captain_assistant, account: account) }
  let(:actor) { create(:captain_assistant, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, status: :pending) }
  let(:anchor) do
    create(:message, conversation: conversation, sender: actor, message_type: :outgoing, private: false,
                     skip_send_reply: true, content: 'Specialist answer',
                     additional_attributes: { captain_ai_reply: { assistant_id: actor.id } })
  end
  let(:reminder) do
    Captain::Conversation::FollowUpJob.build_reminder(
      Captain::Conversation::FollowUpJob.build_schedule_payload(
        conversation, actor, anchor, { index: 0, delay_seconds: 60 },
        { control_generation: conversation.current_captain_control_generation,
          status_transition_id: conversation.status_transitions.maximum(:id).to_i,
          last_message_id: conversation.messages.incoming.maximum(:id) }
      )
    )
  end

  before do
    account.enable_features!('captain_integration')
    create(:captain_inbox, inbox: inbox, captain_assistant: entry)
    entry.update!(handoff_agent_ids: [actor.id])
    actor.update!(handoff_agent_ids: [entry.id])
    create(:message, conversation: conversation, message_type: :incoming, skip_runtime_events: true)
    route_to(actor)
  end

  def route_to(assistant)
    Captain::Conversation::AgentSession.new(entry: entry, conversation: conversation).update_routing(actor_id: assistant.id)
  end

  def expect_ownership_rejected
    expect(reminder).not_to be_valid
    expect(reminder.errors[:assistant]).to include('must currently control the follow-up conversation')
  end

  it 'persists a follow-up for the current reachable specialist without its own inbox assignment' do
    expect(actor.inboxes).to be_empty

    expect { reminder.save! }.to change(described_class, :count).by(1)
    expect(reminder.metadata['captain_follow_up']).to include(
      'assistant_id' => actor.id, 'entry_assistant_id' => entry.id, 'routing_revision' => 1
    )
  end

  it 'rejects an inactive specialist' do
    reminder
    actor.update!(active: false)

    expect_ownership_rejected
  end

  it 'rejects a specialist whose entry is inactive' do
    reminder
    entry.update_columns(active: false)

    expect_ownership_rejected
  end

  it 'rejects a specialist whose route has been removed' do
    reminder
    # Routing is channel membership: the specialist leaves this inbox (selected scope without it).
    actor.update_column(:usage_mode, 'internal_assistant')

    expect_ownership_rejected
  end

  it 'rejects a prepared follow-up after conversation ownership transfers' do
    reminder
    route_to(entry)

    expect_ownership_rejected
  end

  it 'rejects a prepared follow-up after the specialist leaves and returns' do
    reminder
    route_to(entry)
    route_to(actor)

    expect_ownership_rejected
  end

  it 'retains the workspace boundary when an assistant identifier is changed' do
    foreign = create(:captain_assistant)
    metadata = reminder.metadata.deep_dup
    metadata['captain_follow_up']['assistant_id'] = foreign.id
    reminder.metadata = metadata
    reminder.idempotency_key = "captain_follow_up:#{foreign.id}:#{anchor.id}:0"

    expect(reminder).not_to be_valid
    expect(reminder.errors[:account]).to include('must match the Captain assistant')
  end
end
