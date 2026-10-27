require 'rails_helper'

RSpec.describe Captain::Conversation::RunFenceService do
  let(:account) { create(:account) }
  let!(:assistant) { create(:captain_assistant, account: account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:captain_inbox) { create(:captain_inbox, inbox: inbox, reply_to_open_conversations: false) }
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
        status_transition_id: conversation.status_transitions.maximum(:id).to_i,
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

  it 'fences the acting agent switched off by another request after its state was already checked' do
    fence = described_class.new(assistant: assistant, state: state)
    Captain::Assistant.cache do
      fence.ensure_current!
      assistant.update!(active: false)

      expect(assistant).to be_active
      expect { fence.ensure_current! }
        .to raise_error(Captain::Conversation::ControlGenerationStaleError, /assistant_missing/)
    end
  end

  it 'does not fence the run when another agent of the workspace is switched off' do
    peer = create(:captain_assistant, account: account)
    fence = described_class.new(assistant: assistant, state: state)
    fence.ensure_current!
    peer.update!(active: false)

    expect { fence.ensure_current! }.not_to raise_error
  end

  it 'does not fence the run when the agent that was once the default is switched off, if another agent acts' do
    former_default = create(:captain_assistant, account: account)
    fence = described_class.new(assistant: assistant, state: state)
    fence.ensure_current!
    Captain::Assistant.where(id: former_default.id).update_all(active: false)

    expect { fence.ensure_current! }.not_to raise_error
  end

  it 'fences a delegated actor disabled while its loaded model still says active' do
    peer = create(:captain_assistant, account: account)
    current = state.deep_dup.merge(assistant_id: peer.id)
    fence = described_class.new(assistant: peer, state: current)
    fence.ensure_current!
    peer.update!(active: false)

    expect(peer).to be_active
    expect { fence.ensure_current! }
      .to raise_error(Captain::Conversation::ControlGenerationStaleError, /assistant_missing/)
  end

  it 'fences a run whose acting agent was taken out of the channel after an earlier successful check' do
    peer = create(:captain_assistant, account: account)
    current = state.deep_dup.merge(assistant_id: peer.id)
    fence = described_class.new(assistant: peer, state: current)
    fence.ensure_current!
    # Only enabled external agents answer in a text channel.
    peer.update!(usage_mode: 'internal_assistant')

    expect { fence.ensure_current! }
      .to raise_error(Captain::Conversation::ControlGenerationStaleError, /channel_changed/)
  end

  it 'fences the run when the channel is switched off' do
    fence = described_class.new(assistant: assistant, state: state)
    fence.ensure_current!
    captain_inbox.update!(ai_enabled: false)

    expect { fence.ensure_current! }
      .to raise_error(Captain::Conversation::ControlGenerationStaleError, /channel_changed/)
  end

  it 'fences the run when the AI of the workspace is switched off' do
    fence = described_class.new(assistant: assistant, state: state)
    fence.ensure_current!
    Captain::AccountSettings.new(account).update!('routing' => { 'ai_enabled' => false })

    expect { fence.ensure_current! }
      .to raise_error(Captain::Conversation::ControlGenerationStaleError, /channel_changed/)
  end

  it 'fences the run of an output no agent produced when the last agent is switched off' do
    ai_state = state.except(:assistant_id)
    fence = described_class.new(assistant: nil, state: ai_state)
    fence.ensure_current!
    Captain::Assistant.where(account_id: account.id).find_each { |agent| agent.update!(active: false) }

    expect { fence.ensure_current! }
      .to raise_error(Captain::Conversation::ControlGenerationStaleError, /channel_changed/)
  end

  it 'keeps the run of an output no agent produced while any agent is enabled' do
    ai_state = state.except(:assistant_id)
    other = create(:captain_assistant, account: account)
    fence = described_class.new(assistant: nil, state: ai_state)
    fence.ensure_current!
    assistant.update!(active: false)

    expect(other).to be_active
    expect { fence.ensure_current! }.not_to raise_error
  end

  it 'fences an older actor after A to B to A even with the same incoming message' do
    current = state.deep_dup
    session = Captain::Conversation::AgentSession.new(conversation: conversation)
    current[:captain_response_fence][:routing_revision] = session.update_routing(actor_id: assistant.id)
    expect { described_class.new(assistant: assistant, state: current).ensure_current! }.not_to raise_error
    peer = create(:captain_assistant, account: account)
    session.update_routing(actor_id: peer.id)
    session.update_routing(actor_id: assistant.id)
    expect { described_class.new(assistant: assistant, state: current).ensure_current! }
      .to raise_error(Captain::Conversation::ControlGenerationStaleError, /agent_routing_changed/)
  end

  it 'fences the run when a newer incoming message exists' do
    create(:message, account: account, inbox: inbox, conversation: conversation, message_type: :incoming)

    expect { described_class.new(assistant: assistant, state: state).ensure_current! }
      .to raise_error(Captain::Conversation::ControlGenerationStaleError, /last_message_changed/)
    expect(Llm::EventBus).to have_received(:publish).with('captain.run.fenced', hash_including(reason: 'last_message_changed'))
  end

  it 'does not fence an independent channel when a sibling receives a newer message' do
    thread = create(:communication_thread, account: account, contact: conversation.contact)
    sibling = create(:conversation, account: account, contact: conversation.contact, status: :pending)
    [conversation, sibling].each do |candidate|
      create(:communication_thread_conversation, communication_thread: thread, conversation: candidate)
      candidate.association(:communication_thread_conversation).reset
      candidate.association(:communication_thread).reset
    end
    create(:message, conversation: sibling, message_type: :incoming, skip_runtime_events: true)

    expect { described_class.new(assistant: assistant, state: state).ensure_current! }.not_to raise_error
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

  it 'fences a run after an employee reply bumps the generation' do
    expected_state = state
    conversation.activate_captain_human_control!(source: 'agent_reply')

    expect { described_class.new(assistant: assistant, state: expected_state).ensure_current! }
      .to raise_error(Captain::Conversation::ControlGenerationStaleError, /control_generation_changed/)
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

  it 'does not revive an old run after the status cycles from pending to open and back' do
    expected_state = state
    Conversations::StatusTransitionService.new(conversation: conversation, params: { status: 'open' }, source: 'system').perform
    Conversations::StatusTransitionService.new(conversation: conversation, params: { status: 'pending' }, source: 'system').perform

    expect(conversation.reload).to be_pending
    expect { described_class.new(assistant: assistant, state: expected_state).ensure_current! }
      .to raise_error(Captain::Conversation::ControlGenerationStaleError, /status_epoch_changed/)
  end
end
