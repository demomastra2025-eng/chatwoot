require 'rails_helper'

RSpec.describe Conversations::StatusTransitionService do
  let(:account) { create(:account) }
  let(:conversation) { create(:conversation, account: account, status: 'open') }
  let(:agent) { create(:user, account: account, role: :agent) }


  def transition(params:, source: 'manual', actor: agent)
    described_class.new(
      conversation: conversation,
      params: params,
      actor: actor,
      source: source
    ).perform
  end

  it 'changes status and writes an audit transition without reasons by default' do
    expect do
      transition(params: { status: 'resolved' })
    end.to change { ConversationStatusTransition.count }.by(1)

    transition_record = ConversationStatusTransition.last
    expect(conversation.reload.status).to eq('resolved')
    expect(transition_record).to have_attributes(
      account: account,
      conversation: conversation,
      actor: agent,
      from_status: 'open',
      to_status: 'resolved',
      reason: nil,
      source: 'manual'
    )
  end


  it 'records a prevalidated agent outcome reason and analytics metadata' do
    described_class.new(
      conversation: conversation,
      params: { status: 'resolved' },
      actor: agent,
      source: 'captain',
      audit: {
        reason_override: 'Цель достигнута',
        metadata: {
          outcome_reason_id: 'goal_achieved',
          outcome_reason_type: 'completion',
          assistant_id: 42
        }
      }
    ).perform

    expect(conversation.status_transitions.last).to have_attributes(
      reason: 'Цель достигнута',
      source: 'captain',
      metadata: include(
        'outcome_reason_id' => 'goal_achieved',
        'outcome_reason_type' => 'completion',
        'assistant_id' => 42
      )
    )
  end

  it 'applies the status atomically to every channel projection in the communication thread' do
    account.enable_features!('communication_threads')
    contact = create(:contact, account: account)
    first_conversation = create(:conversation, account: account, contact: contact, status: 'open')
    second_conversation = create(:conversation, account: account, contact: contact, status: 'pending')

    described_class.new(
      conversation: first_conversation,
      params: { status: 'resolved' },
      actor: agent,
      source: 'api'
    ).perform

    expect(contact.conversations.reload.pluck(:status).uniq).to eq(['resolved'])
    expect(contact.communication_threads.reload.pluck(:status).uniq).to eq(['resolved'])
    expect(second_conversation.status_transitions.last).to have_attributes(
      from_status: 'pending',
      to_status: 'resolved',
      source: 'api'
    )
  end
end
