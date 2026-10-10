require 'rails_helper'

RSpec.describe Captain::Conversation::FollowUpControlFence do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account, usage_mode: 'external_agent') }
  let(:conversation) { create(:conversation, account: account, status: :pending) }

  before do
    create(:captain_inbox, inbox: conversation.inbox, captain_assistant: assistant)
    conversation.inbox.reload
  end

  it 'recovers a legacy follow-up fence from its own incoming request instead of a newer sibling request' do
    own_message = create(:message, conversation: conversation, message_type: :incoming, skip_runtime_events: true)
    thread = create(:communication_thread, account: account, contact: conversation.contact)
    sibling = create(:conversation, account: account, contact: conversation.contact, status: :pending)
    create(:captain_inbox, inbox: sibling.inbox, captain_assistant: assistant)
    sibling.inbox.reload
    [conversation, sibling].each do |candidate|
      create(:communication_thread_conversation, communication_thread: thread, conversation: candidate)
      candidate.association(:communication_thread_conversation).reset
      candidate.association(:communication_thread).reset
    end
    create(:message, conversation: sibling, message_type: :incoming, skip_runtime_events: true)
    anchor = create(:message, conversation: conversation, sender: assistant, message_type: :outgoing,
                              additional_attributes: { captain_ai_reply: { assistant_id: assistant.id } })
    reminder = build(:reminder, account: account, conversation: conversation, action_type: :captain_follow_up)

    fence = described_class.resolve(reminder: reminder, conversation: conversation, assistant: assistant, anchor_message: anchor)

    expect(fence).to include('last_message_id' => own_message.id, 'control_generation' => conversation.current_captain_control_generation)
  end
end
