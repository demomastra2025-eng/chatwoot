require 'rails_helper'

RSpec.describe Captain::Conversation::RunFenceService do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:captain_inbox) { create(:captain_inbox, inbox: inbox, captain_assistant: assistant, reply_to_open_conversations: false) }
  let(:conversation) do
    captain_inbox
    create(:conversation, account: account, inbox: inbox, status: :pending)
  end
  let!(:trigger_message) { create(:message, account: account, inbox: inbox, conversation: conversation, message_type: :incoming) }
  let(:buffer_token) { 'current-buffer-token' }
  let(:state) do
    {
      account_id: account.id,
      assistant_id: assistant.id,
      conversation: { id: conversation.id },
      captain_response_fence: {
        control_generation: conversation.captain_control_generation,
        last_message_id: trigger_message.id,
        buffer_token: buffer_token
      }
    }
  end
  let(:state_key) { format(Redis::Alfred::CAPTAIN_MESSAGE_BUFFER_STATE, conversation_id: conversation.id) }

  before do
    Redis::Alfred.set(
      state_key,
      {
        token: buffer_token,
        assistant_id: assistant.id,
        last_message_id: trigger_message.id,
        control_generation: conversation.captain_control_generation
      }.to_json,
      ex: 60
    )
    allow(Llm::EventBus).to receive(:publish)
  end

  after do
    Redis::Alfred.delete(state_key)
  end

  it 'allows the tool while token, message, status, assistant and ownership generation are current' do
    expect { described_class.new(assistant: assistant, state: state).ensure_current! }.not_to raise_error
  end

  it 'fences the run when a newer incoming message exists' do
    create(:message, account: account, inbox: inbox, conversation: conversation, message_type: :incoming)

    expect { described_class.new(assistant: assistant, state: state).ensure_current! }
      .to raise_error(Captain::Conversation::ControlGenerationStaleError, /last_message_changed/)
    expect(Llm::EventBus).to have_received(:publish).with('captain.run.fenced', hash_including(reason: 'last_message_changed'))
  end

  it 'fences the run when the Redis buffer token changes' do
    Redis::Alfred.set(
      state_key,
      {
        token: 'new-buffer-token',
        assistant_id: assistant.id,
        last_message_id: trigger_message.id,
        control_generation: conversation.captain_control_generation
      }.to_json,
      ex: 60
    )

    expect { described_class.new(assistant: assistant, state: state).ensure_current! }
      .to raise_error(Captain::Conversation::ControlGenerationStaleError, /buffer_state_changed/)
  end

  it 'fences the run after human ownership is activated' do
    conversation.activate_captain_human_control!(source: 'agent_reply')

    expect { described_class.new(assistant: assistant, state: state).ensure_current! }
      .to raise_error(Captain::Conversation::ControlGenerationStaleError, /human_control/)
  end

  it 'fences the run when a human reply committed before its ownership callback acquired the lock' do
    create(:message, account: account, inbox: inbox, conversation: conversation, message_type: :outgoing)
    conversation.update!(captain_control_state: 'ai', captain_control_generation: 0, status: :pending)

    expect(conversation.reload.captain_control_state).to eq('ai')
    expect { described_class.new(assistant: assistant, state: state).ensure_current! }
      .to raise_error(Captain::Conversation::ControlGenerationStaleError, /human_response_committed/)
  end

  it 'fences the run after the conversation becomes ineligible' do
    conversation.update!(status: :open)

    expect { described_class.new(assistant: assistant, state: state).ensure_current! }
      .to raise_error(Captain::Conversation::ControlGenerationStaleError, /status_changed/)
  end
end
