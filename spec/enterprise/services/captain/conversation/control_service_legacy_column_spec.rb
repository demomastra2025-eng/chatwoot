require 'rails_helper'

# Captain v4 decides AI vs human control only from the conversation status.
# The legacy captain_control_state column is still mirrored (write-only) so the
# previous release image, which reads it, keeps the human-ownership rule while
# old and new containers overlap during a rollout and after a rollback.
RSpec.describe Captain::Conversation::ControlService do
  let(:account) { create(:account) }
  let(:agent) { create(:user, account: account) }
  let(:conversation) { create(:conversation, account: account, status: :pending) }

  def legacy_state
    conversation.captain_control_owner.reload.captain_control_state
  end

  it 'mirrors human control when an employee takes over' do
    expect(conversation.activate_captain_human_control!(source: 'agent_reply')).to be true

    expect(legacy_state).to eq('human')
  end

  it 'mirrors human control on a Captain handoff' do
    expect(conversation.bot_handoff!).to eq(:applied)

    expect(conversation.reload).to be_open
    expect(legacy_state).to eq('human')
  end

  it 'mirrors human control when a handoff finds an employee already assigned' do
    conversation.update_columns(assignee_id: agent.id) # rubocop:disable Rails/SkipsModelValidations

    expect(conversation.bot_handoff!).to eq(:already_applied)

    expect(conversation.reload).to be_open
    expect(legacy_state).to eq('human')
  end

  it 'mirrors AI control when an employee returns the conversation to Captain' do
    conversation.bot_handoff!

    Conversations::StatusTransitionService.new(
      conversation: conversation, params: { status: 'pending' }, actor: agent, source: 'api'
    ).perform

    expect(conversation.reload).to be_pending
    expect(legacy_state).to eq('ai')
  end

  it 'never lets the mirrored column decide control' do
    conversation.update_columns(captain_control_state: 'human') # rubocop:disable Rails/SkipsModelValidations
    expect(conversation.reload.current_captain_control_state).to eq('ai')

    conversation.update_columns(status: 'open', captain_control_state: 'ai') # rubocop:disable Rails/SkipsModelValidations
    expect(conversation.reload.current_captain_control_state).to eq('human')
  end
end
