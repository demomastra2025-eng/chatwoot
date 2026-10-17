# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Captain follow-up agent ownership', type: :job do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, status: :pending) }
  let(:entry) { create(:captain_assistant, account: account, config: follow_up_config('Entry follow-up')) }
  let(:actor) { create(:captain_assistant, account: account, config: follow_up_config('Specialist follow-up')) }

  before do
    account.enable_features!('captain_integration', 'captain_tasks')
    create(:captain_inbox, inbox: inbox, captain_assistant: entry)
    entry.update!(handoff_agent_ids: [actor.id])
    create(:message, conversation: conversation, message_type: :incoming, content: 'Can you help?')
    evaluator = instance_double(Captain::ConversationCompletionEvaluator, perform: { evaluated: true, complete: false })
    allow(Captain::ConversationCompletionEvaluator).to receive(:new).and_return(evaluator)
  end

  def follow_up_config(content)
    {
      'follow_up_settings' => {
        'enabled' => true,
        'prompt' => '',
        'steps' => [
          { 'mode' => 'static', 'message' => content, 'delay_seconds' => 60 },
          { 'mode' => 'static', 'message' => "#{content} again", 'delay_seconds' => 120 }
        ]
      }
    }
  end

  def route_to(assistant)
    Captain::Conversation::AgentSession.new(entry: entry, conversation: conversation).update_routing(actor_id: assistant.id)
  end

  def anchor_for(assistant, candidate: conversation)
    create(:message, conversation: candidate, sender: assistant, message_type: :outgoing, private: false,
                     content: 'Original answer', additional_attributes: { captain_ai_reply: { assistant_id: assistant.id } })
  end

  def schedule_for(assistant, anchor:, candidate: conversation)
    reminder = Captain::Conversation::FollowUpJob.schedule!(
      conversation: candidate, assistant: assistant, anchor_message: anchor,
      step: { index: 0, delay_seconds: 60 },
      control_fence: {
        control_generation: candidate.current_captain_control_generation,
        status_transition_id: candidate.status_transitions.maximum(:id).to_i,
        last_message_id: candidate.messages.incoming.maximum(:id)
      }
    )
    expect(reminder).to be_a(Reminder)
    reminder
  end

  def current?(reminder, assistant, anchor)
    Captain::Conversation::FollowUpGuard.current?(
      reminder: reminder, conversation: conversation, assistant: assistant.reload, anchor_message: anchor
    )
  end

  def materialize(reminder, assistant, anchor)
    reminder.mark_processing!
    delivery = lambda do |content, attributes|
      Reminders::MessageMaterializer.new(reminder: reminder, additional_attributes: attributes).perform(
        conversation: conversation, sender: assistant, content: content, delivery_policy: nil
      )
    end
    Captain::Conversation::FollowUpJob.new.perform_for_reminder(
      reminder: reminder, conversation: conversation, assistant: assistant,
      anchor_message: anchor, delivery: delivery
    )
  end

  it 'uses the current specialist settings and sender without a channel assignment of its own' do
    route_to(actor)
    anchor = anchor_for(actor)
    reminder = schedule_for(actor, anchor: anchor)

    expect(actor.inboxes).to be_empty
    expect(reminder.metadata['captain_follow_up']).to include(
      'assistant_id' => actor.id, 'entry_assistant_id' => entry.id, 'routing_revision' => 1
    )
    message = materialize(reminder, actor, anchor)
    expect(message.content).to eq('Specialist follow-up')
    expect(message.sender).to eq(actor)
    expect(message.additional_attributes['captain_follow_up']).to include('routing_revision' => 1)
    provider = spy('provider')
    Captain::Conversation::FollowUpDispatchGuard.with_provider_boundary(message) { provider.submit(message.id) }
    expect(provider).to have_received(:submit).with(message.id).once
  end

  it 'never revives an old chain after A to B to A, including the delivery completion callback' do
    route_to(actor)
    anchor = anchor_for(actor)
    reminder = schedule_for(actor, anchor: anchor)
    message = materialize(reminder, actor, anchor)

    route_to(entry)
    expect(current?(reminder, actor, anchor)).to be(false)
    route_to(actor)
    expect(current?(reminder, actor, anchor)).to be(false)
    expect do
      Captain::Conversation::FollowUpJob.schedule_after_delivery!(reminder: reminder, message: message)
    end.not_to change(Reminder, :count)
    provider = spy('provider')
    Captain::Conversation::FollowUpDispatchGuard.with_provider_boundary(message) { provider.submit(message.id) }
    expect(provider).not_to have_received(:submit)
    expect(message.reload).to be_failed
  end

  it 'accepts an unstamped legacy entry chain only before any transfer' do
    anchor = anchor_for(entry)
    reminder = schedule_for(entry, anchor: anchor)
    metadata = reminder.metadata.deep_dup
    metadata['captain_follow_up'].except!('routing_revision', 'entry_assistant_id')
    reminder.update_column(:metadata, metadata) # rubocop:disable Rails/SkipsModelValidations

    expect(current?(reminder, entry, anchor)).to be(true)
    route_to(actor)
    route_to(entry)
    expect(current?(reminder, entry, anchor)).to be(false)
  end

  %w[transfer deactivate remove_membership].each do |change|
    it "rechecks #{change} before sending a materialized static follow-up" do
      route_to(actor)
      anchor = anchor_for(actor)
      reminder = schedule_for(actor, anchor: anchor)
      message = materialize(reminder, actor, anchor)
      case change
      when 'transfer' then route_to(entry)
      when 'deactivate' then actor.update!(active: false)
      when 'remove_membership' then actor.update_column(:usage_mode, 'internal_assistant')
      end
      provider = spy('provider')

      Captain::Conversation::FollowUpDispatchGuard.with_provider_boundary(message) { provider.submit(message.id) }

      expect(provider).not_to have_received(:submit)
      expect(reminder.reload).to be_captain_follow_up_delivery_suppressed
      expect(message.reload).to be_failed
    end
  end

  it 'keeps a part-bound follow-up eligible after another channel member becomes the owner' do
    route_to(actor)
    part_id = SecureRandom.uuid
    session = Captain::Conversation::AgentSession.new(entry: entry, conversation: conversation)
    session.change do |data|
      data['parts'] = [{ 'id' => part_id, 'version' => 1, 'executor_agent_id' => actor.id,
                         'state' => 'answered', 'delivered' => [] }]
    end
    anchor = create(:message, conversation: conversation, sender: actor, message_type: :outgoing,
                              private: false, content: 'Answer',
                              additional_attributes: { captain_ai_reply: { assistant_id: actor.id },
                                                       captain_part_refs: [{ id: part_id, version: 1 }] })
    reminder = schedule_for(actor, anchor: anchor)

    route_to(entry)

    expect(current?(reminder, actor, anchor)).to be(true)
    expect(reminder.metadata.dig('captain_follow_up', 'part_id')).to eq(part_id)
  end

  it 'keeps sibling physical reminders when one conversation changes while shared human control revokes their delivery' do
    sibling_inbox = create(:inbox, account: account)
    CaptainInbox.find_or_create_by!(inbox: sibling_inbox) { |ci| ci.captain_assistant = entry }
    sibling = create(:conversation, account: account, inbox: sibling_inbox, contact: conversation.contact, status: :pending)
    thread = create(:communication_thread, account: account, contact: conversation.contact)
    [conversation, sibling].each do |candidate|
      create(:communication_thread_conversation, communication_thread: thread, conversation: candidate)
      candidate.association(:communication_thread_conversation).reset
      candidate.association(:communication_thread).reset
    end
    create(:message, conversation: sibling, message_type: :incoming, skip_runtime_events: true)
    own_anchor = anchor_for(entry)
    sibling_anchor = anchor_for(entry, candidate: sibling)
    own_reminder = schedule_for(entry, anchor: own_anchor)
    sibling_reminder = schedule_for(entry, anchor: sibling_anchor, candidate: sibling)

    Captain::Conversation::FollowUpChainService.cancel_for!(conversation, reason: 'Conversation status changed')

    expect(own_reminder.reload).to be_cancelled
    expect(sibling_reminder.reload).to be_pending
    conversation.activate_captain_human_control!(source: 'manual', actor: create(:user, account: account))
    expect(Captain::Conversation::FollowUpGuard.current?(
             reminder: sibling_reminder, conversation: sibling, assistant: entry, anchor_message: sibling_anchor
           )).to be(false)
  end
end
