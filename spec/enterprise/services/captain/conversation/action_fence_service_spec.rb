# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::Conversation::ActionFenceService do
  let(:account) { create(:account) }
  let(:channel) { create(:channel_widget, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: channel.inbox, status: :pending) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:incoming) { create(:message, conversation: conversation, message_type: :incoming) }
  let(:state) do
    {
      account_id: account.id,
      assistant_id: assistant.id,
      conversation: { id: conversation.id },
      captain_response_fence: {
        control_generation: conversation.current_captain_control_generation,
        last_message_id: incoming.id
      }
    }
  end

  before do
    account.enable_features!('scheduling')
    create(:captain_inbox, captain_assistant: assistant, inbox: channel.inbox)
  end

  def call_action(run_state = state, &)
    described_class.new(assistant: assistant, state: run_state).with_effect!(&)
  end

  it 'executes an action while the current run retains AI control' do
    effects = []
    expect(call_action { effects << :created }).to eq([:created])
    expect(effects).to eq([:created])
  end

  it 'stamps the generation on an async provider command without leaking it to the next request' do
    hook = create(:integrations_hook, :medelement, account: account)
    service = Integrations::Medelement::ProviderCommands::CreateService.new(
      account: account, hook: hook, operation: 'create_patient', idempotency_key: 'captain-run'
    )
    attributes = call_action do
      service.send(:command_attributes, snapshot: {}, request_fingerprint: 'request', intent_fingerprint: 'intent')
    end

    expect(attributes[:execution_state]['captain_action_origin']).to include(
      'assistant_id' => assistant.id,
      'conversation_id' => conversation.id,
      'control_generation' => state.dig(:captain_response_fence, :control_generation)
    )
    expect(described_class.current_origin).to be_nil
    expect(service.send(:command_attributes, snapshot: {}, request_fingerprint: 'request', intent_fingerprint: 'intent')[:execution_state])
      .not_to have_key('captain_action_origin')
  end

  it 'blocks a delayed mutating tool if a human replied before the effect' do
    original = state
    create(:message, conversation: conversation, message_type: :outgoing, sender: create(:user, account: account))
    effects = []

    expect { call_action(original) { effects << :created } }
      .to raise_error(Captain::Conversation::ControlGenerationStaleError)
    expect(effects).to be_empty
  end

  it 'blocks stale work even after AI is reactivated at a new generation' do
    original = state
    create(:message, conversation: conversation, message_type: :outgoing, sender: create(:user, account: account))
    conversation.prepare_captain_ai_control!
    effects = []

    expect { call_action(original) { effects << :created } }
      .to raise_error(Captain::Conversation::ControlGenerationStaleError)
    expect(effects).to be_empty
  end

  it 'blocks action when a handoff committed before the effect' do
    original = state
    conversation.activate_captain_human_control!(source: 'captain_handoff')

    expect { call_action(original) { raise 'must not run' } }
      .to raise_error(Captain::Conversation::ControlGenerationStaleError)
  end

  it 'rejects a conversation-scoped legacy action without its generation token' do
    without_fence = state.except(:captain_response_fence)

    expect { call_action(without_fence) { raise 'must not run' } }
      .to raise_error(Captain::Conversation::ControlGenerationStaleError, /control changed/)
  end
end
