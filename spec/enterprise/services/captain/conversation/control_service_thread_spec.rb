require 'rails_helper'

RSpec.describe Captain::Conversation::ControlService do
  let(:account) { create(:account) }
  let(:contact) { create(:contact, account: account) }
  let(:thread) { create(:communication_thread, account: account, contact: contact) }
  let(:first_conversation) { create(:conversation, account: account, contact: contact, status: :pending) }
  let(:second_conversation) { create(:conversation, account: account, contact: contact, status: :pending) }

  before do
    create(:communication_thread_conversation, communication_thread: thread, conversation: first_conversation)
    create(:communication_thread_conversation, communication_thread: thread, conversation: second_conversation)
    [first_conversation, second_conversation].each do |conversation|
      conversation.association(:communication_thread_conversation).reset
      conversation.association(:communication_thread).reset
    end
  end

  it 'moves every linked conversation to human control with one thread generation' do
    stale_generation = second_conversation.current_captain_control_generation

    first_conversation.activate_captain_human_control!(source: 'agent_reply')

    expect(thread.reload).to have_attributes(
      captain_control_state: 'human',
      captain_control_generation: stale_generation + 1
    )
    expect(second_conversation.reload).to be_captain_human_control_active
    expect(second_conversation.bot_handoff!(fence: { control_generation: stale_generation })).to eq(:stale)
  end

  it 'returns the thread to AI control once and invalidates older generations' do
    first_conversation.activate_captain_human_control!(source: 'agent_reply')
    human_generation = thread.reload.captain_control_generation

    expect(second_conversation.prepare_captain_ai_control!).to be(true)
    expect(first_conversation.reload).not_to be_captain_human_control_active
    expect(thread.reload).to have_attributes(
      captain_control_state: 'ai',
      captain_control_generation: human_generation + 1,
      captain_handoff_applied_at: nil
    )
  end

  it 'locks the thread owner before the conversation during explicit release' do
    agent = create(:user, account: account)
    first_conversation.activate_captain_human_control!(source: 'agent_reply')
    expect(second_conversation).to receive(:with_captain_control_lock).ordered.and_call_original
    expect(second_conversation).to receive(:with_lock).ordered.and_call_original

    Conversations::StatusTransitionService.new(
      conversation: second_conversation,
      params: { status: 'pending' },
      actor: agent,
      source: 'api'
    ).perform

    expect(thread.reload.captain_control_state).to eq('ai')
  end
end
