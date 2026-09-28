require 'rails_helper'

RSpec.describe Captain::Tools::ProviderBookingHandoffService do
  let(:account) { create(:account, locale: 'ru') }
  let(:assistant) { create(:captain_assistant, account: account, usage_mode: 'external_agent') }
  let(:conversation) { create(:conversation, account: account, status: :pending) }
  let(:incoming) { create(:message, conversation: conversation, message_type: :incoming) }
  let(:fence) do
    {
      control_generation: conversation.current_captain_control_generation,
      status_transition_id: conversation.status_transitions.maximum(:id).to_i,
      last_message_id: incoming.id
    }
  end

  before { create(:captain_inbox, inbox: conversation.inbox, captain_assistant: assistant) }

  it 'opens a system-authorized human handoff with one private staff note' do
    service = described_class.new(assistant: assistant, conversation: conversation, fence: fence)

    expect(service.perform).to eq(:applied)
    expect(service.perform).to eq(:stale)
    expect(conversation.reload.status).to eq('open')
    expect(conversation.current_captain_control_state).to eq('human')
    expect(conversation.messages.outgoing.where(private: false)).to be_empty
    expect(conversation.messages.outgoing.where(private: true).count).to eq(1)
  end

  it 'does not hand off when a newer Captain control generation exists' do
    captured_fence = fence
    conversation.activate_captain_human_control!(source: 'test')
    conversation.update!(status: :open)
    conversation.prepare_captain_ai_control!
    conversation.update!(status: :pending)

    result = described_class.new(assistant: assistant, conversation: conversation, fence: captured_fence).perform

    expect(result).to eq(:stale)
    expect(conversation.reload.status).to eq('pending')
    expect(conversation.messages.outgoing).to be_empty
  end

  it 'does not leave a late note after a newer Captain run has handed off to another human' do
    captured_fence = fence
    conversation.update!(status: :open)
    conversation.prepare_captain_ai_control!
    conversation.update!(status: :pending)
    conversation.update!(status: :open)

    expect(described_class.new(assistant: assistant, conversation: conversation, fence: captured_fence).perform).to eq(:stale)
    expect(conversation.messages.outgoing).to be_empty
  end

  it 'does not accept a forged cross-account assistant' do
    other_assistant = create(:captain_assistant, account: create(:account))

    expect(described_class.new(assistant: other_assistant, conversation: conversation, fence: fence).perform).to eq(:invalid_context)
    expect(conversation.reload.status).to eq('pending')
  end

  it 'does not take over a conversation whose inbox belongs to a different Captain assistant' do
    replacement = create(:captain_assistant, account: account, usage_mode: 'external_agent')
    conversation.inbox.captain_inbox.update!(captain_assistant: replacement)

    expect(described_class.new(assistant: assistant, conversation: conversation, fence: fence).perform).to eq(:invalid_context)
    expect(conversation.reload.status).to eq('pending')
    expect(conversation.messages.outgoing).to be_empty
  end

  it 'records a staff note when a human is already assigned to a pending conversation' do
    conversation.update!(assignee: create(:user, account: account))

    expect(described_class.new(assistant: assistant, conversation: conversation, fence: fence).perform).to eq(:already_applied)
    expect(conversation.reload.status).to eq('open')
    expect(conversation.messages.outgoing.where(private: true).count).to eq(1)
  end

  it 'records a staff note after an agent public reply took the conversation over' do
    agent = create(:user, account: account, role: :agent)
    create(:inbox_member, user: agent, inbox: conversation.inbox)
    captured_fence = fence
    create(:message, conversation: conversation, account: account, inbox: conversation.inbox, message_type: :outgoing,
                     sender: agent, private: false, content: 'agent reply')
    conversation.reload

    expect(conversation.status).to eq('open')
    expect(conversation.current_captain_control_generation.to_i).to eq(captured_fence[:control_generation].to_i + 1)
    expect(described_class.new(assistant: assistant, conversation: conversation, fence: captured_fence).perform).to eq(:stale)
    expect(conversation.messages.outgoing.where(private: true).count).to eq(1)
  end

  it 'does not let the legacy captain_control_state column decide a late note' do
    captured_fence = fence
    conversation.update!(status: :open)
    conversation.prepare_captain_ai_control!
    conversation.update!(status: :pending)
    conversation.update!(status: :open)
    conversation.captain_control_owner.update_column(:captain_control_state, 'human') # rubocop:disable Rails/SkipsModelValidations

    expect(described_class.new(assistant: assistant, conversation: conversation, fence: captured_fence).perform).to eq(:stale)
    expect(conversation.messages.outgoing).to be_empty
  end

  it 'fails closed without a response fence' do
    expect(described_class.new(assistant: assistant, conversation: conversation).perform).to eq(:missing_fence)
    expect(conversation.reload.status).to eq('pending')
  end
end
