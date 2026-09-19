require 'rails_helper'

RSpec.describe Captain::Tools::BasePublicTool do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:conversation) { create(:conversation, account: account, status: :pending) }
  let(:run_context) do
    instance_double(
      Captain::Runtime::RunContext,
      context: {
        state: {
          conversation: { id: conversation.id },
          captain_control_generation: expected_generation
        }
      },
      usage: {}
    )
  end
  let(:tool_context) { Captain::Runtime::ToolContext.new(run_context: run_context) }
  let(:tool) { Captain::Tools::HandoffTool.new(assistant) }
  let(:expected_generation) { 0 }

  before do
    allow(Captain::ToolPolicy).to receive(:execution_allowed?).and_return(true)
    allow(Captain::ToolExecutionAuditService).to receive(:record)
  end

  it 'allows a tool while the AI control generation is current' do
    expect do
      tool.execute(tool_context, reason: 'Needs a human')
    end.not_to raise_error

    expect(run_context.context[:pending_human_handoff]).to include(reason: 'Needs a human')
  end

  it 'blocks a tool after a human takes control' do
    conversation.activate_captain_human_control!(source: 'agent_reply')

    expect do
      tool.execute(tool_context, reason: 'Stale action')
    end.to raise_error(
      Captain::Conversation::ControlGenerationStaleError,
      'Captain control changed before tool execution'
    )
    expect(run_context.context[:pending_human_handoff]).to be_nil
  end

  it 'blocks an old tool run after control returns to AI in a newer generation' do
    agent = create(:user, account: account)
    conversation.activate_captain_human_control!(source: 'agent_reply', actor: agent)
    Conversations::StatusTransitionService.new(
      conversation: conversation,
      params: { status: 'pending' },
      actor: agent,
      source: 'api'
    ).perform

    expect do
      tool.execute(tool_context, reason: 'Old generation')
    end.to raise_error(Captain::Conversation::ControlGenerationStaleError)
  end

  it 'uses the communication thread generation for legacy tool contexts' do
    contact = conversation.contact
    thread = create(:communication_thread, account: account, contact: contact)
    first_conversation = create(:conversation, account: account, contact: contact, status: :pending)
    create(:communication_thread_conversation, communication_thread: thread, conversation: first_conversation)
    create(:communication_thread_conversation, communication_thread: thread, conversation: conversation)
    [first_conversation, conversation].each do |linked_conversation|
      linked_conversation.association(:communication_thread_conversation).reset
      linked_conversation.association(:communication_thread).reset
    end

    first_conversation.activate_captain_human_control!(source: 'agent_reply')

    expect do
      tool.execute(tool_context, reason: 'Stale linked-conversation action')
    end.to raise_error(Captain::Conversation::ControlGenerationStaleError)
  end
end
