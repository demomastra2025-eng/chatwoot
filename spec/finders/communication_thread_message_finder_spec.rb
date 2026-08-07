require 'rails_helper'

describe CommunicationThreadMessageFinder do
  subject(:finder) do
    described_class.new(
      communication_thread: communication_thread,
      current_user: user
    )
  end

  let(:account) { create(:account) }
  let(:user) { create(:user, :administrator, account: account) }
  let(:contact) { create(:contact, account: account) }
  let(:communication_thread) { create(:communication_thread, account: account, contact: contact) }
  let(:first_conversation) { create_linked_conversation }
  let(:second_conversation) { create_linked_conversation }

  before do
    allow(user).to receive(:account).and_return(account)
  end

  def create_linked_conversation
    inbox = create(:inbox, account: account)
    contact_inbox = create(:contact_inbox, contact: contact, inbox: inbox)
    conversation = create(
      :conversation,
      account: account,
      inbox: inbox,
      contact: contact,
      contact_inbox: contact_inbox
    )
    create(
      :communication_thread_conversation,
      account: account,
      communication_thread: communication_thread,
      conversation: conversation,
      inbox: inbox,
      contact_inbox: contact_inbox
    )
    conversation
  end

  it 'shows useful activity and regular messages while hiding noisy telemetry' do
    regular_message = create(
      :message,
      conversation: first_conversation,
      account: account,
      inbox: first_conversation.inbox
    )
    useful_activity = create(
      :message,
      message_type: 'activity',
      content: 'Conversation assigned to Alex',
      conversation: first_conversation,
      account: account,
      inbox: first_conversation.inbox
    )
    noisy_activity = create(
      :message,
      message_type: 'activity',
      source_id: 'ai_voice_event:call:caller_interrupted:1',
      conversation: first_conversation,
      account: account,
      inbox: first_conversation.inbox
    )

    result = finder.perform

    expect(result).to include(regular_message, useful_activity)
    expect(result).not_to include(noisy_activity)
  end

  it 'preserves distinct cross-channel activities with the same content' do
    created_at = Time.zone.local(2026, 8, 7, 10, 0, 0)
    first_activity = create(
      :message,
      message_type: 'activity',
      content: 'Conversation resolved by Alex',
      created_at: created_at,
      conversation: first_conversation,
      account: account,
      inbox: first_conversation.inbox
    )
    create(
      :message,
      message_type: 'activity',
      content: first_activity.content,
      created_at: created_at + 0.1.seconds,
      conversation: second_conversation,
      account: account,
      inbox: second_conversation.inbox
    )

    result = finder.perform

    expect(result.count { |message| message.content == first_activity.content }).to eq(2)
  end

  it 'uses the timeline position of a hidden telemetry cursor' do
    early_message = create(
      :message,
      created_at: Time.zone.local(2026, 8, 7, 10, 0, 0),
      conversation: first_conversation,
      account: account,
      inbox: first_conversation.inbox
    )
    late_message = create(
      :message,
      created_at: Time.zone.local(2026, 8, 7, 12, 0, 0),
      conversation: first_conversation,
      account: account,
      inbox: first_conversation.inbox
    )
    hidden_cursor = create(
      :message,
      message_type: 'activity',
      source_id: 'ai_voice_event:call:ai_speaking:cursor',
      created_at: Time.zone.local(2026, 8, 7, 11, 0, 0),
      conversation: first_conversation,
      account: account,
      inbox: first_conversation.inbox
    )

    result = described_class.new(
      communication_thread: communication_thread,
      current_user: user,
      params: { after: hidden_cursor.id }
    ).perform

    expect(result).to include(late_message)
    expect(result).not_to include(early_message, hidden_cursor)
  end
end
