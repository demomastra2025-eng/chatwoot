require 'rails_helper'

RSpec.describe Conversations::StatusTransitionService do
  let(:account) { create(:account) }
  let(:conversation) { create(:conversation, account: account, status: 'open') }
  let(:agent) { create(:user, account: account, role: :agent) }

  def configure_status_reasons(status, options:, required: false)
    account.update!(
      conversation_status_reason_config: {
        status.to_s => {
          options: options,
          required: required
        }
      }
    )
  end

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

  it 'rolls back the status change if the audit transition cannot be written' do
    allow(ConversationStatusTransition).to receive(:create!).and_raise(ActiveRecord::RecordNotSaved, 'audit unavailable')

    expect do
      transition(params: { status: 'pending' }, source: 'system', actor: nil)
    end.to raise_error(ActiveRecord::RecordNotSaved, 'audit unavailable')

    expect(conversation.reload.status).to eq('open')
  end

  it 'returns ownership to Captain when an agent explicitly resolves a human-owned conversation' do
    allow(Llm::EventBus).to receive(:publish)
    conversation.activate_captain_human_control!(source: 'agent_reply', actor: agent)
    human_generation = conversation.reload.captain_control_generation

    transition(params: { status: 'resolved' })

    expect(conversation.reload).to have_attributes(
      status: 'resolved',
      captain_control_generation: human_generation + 1,
      captain_handoff_applied_at: nil
    )
    expect(conversation.current_captain_control_state).to eq('human')
    expect(Llm::EventBus).to have_received(:publish).with(
      'captain.control.ai_activated',
      hash_including(conversation_id: conversation.id, source: 'manual')
    )
  end

  it 'returns ownership to Captain for an explicit bulk resolve' do
    conversation.activate_captain_human_control!(source: 'agent_reply', actor: agent)

    described_class.new(
      conversation: conversation,
      params: { status: 'resolved' },
      actor: agent,
      source: 'bulk_action'
    ).perform

    expect(conversation.reload).to have_attributes(status: 'resolved')
    expect(conversation.current_captain_control_state).to eq('human')
  end

  it 'requires configured reasons for manual transitions' do
    configure_status_reasons(:resolved, options: ['Вопрос решён'], required: true)

    expect do
      transition(params: { status: 'resolved' })
    end.to raise_error(Conversations::StatusReasonConfig::Error) { |error|
      expect(error.code).to eq('CONVERSATION_STATUS_REASON_REQUIRED')
      expect(error.details).to include(reason_options: ['Вопрос решён'])
    }

    expect(conversation.reload.status).to eq('open')
  end

  it 'canonicalizes configured reasons case-insensitively' do
    configure_status_reasons(:resolved, options: ['Вопрос решён'], required: true)

    transition(params: { status: 'resolved', status_reason: 'вопрос решён' })

    expect(conversation.reload.status).to eq('resolved')
    expect(conversation.status_transitions.last.reason).to eq('Вопрос решён')
  end

  it 'rejects unconfigured submitted reasons' do
    configure_status_reasons(:resolved, options: ['Вопрос решён'], required: false)

    expect do
      transition(params: { status: 'resolved', status_reason: 'Свободный текст' })
    end.to raise_error(Conversations::StatusReasonConfig::Error) { |error|
      expect(error.code).to eq('CONVERSATION_STATUS_REASON_INVALID')
      expect(error.details).to include(invalid_reason: 'Свободный текст')
    }
  end

  it 'does not enforce required reasons when the status is unchanged' do
    configure_status_reasons(:open, options: ['Back to operator'], required: true)

    expect do
      transition(params: { status: 'open' })
    end.not_to(change { ConversationStatusTransition.count })

    expect(conversation.reload.status).to eq('open')
  end

  it 'does not enforce required reasons for source-aware system transitions' do
    configure_status_reasons(:resolved, options: ['Вопрос решён'], required: true)

    transition(params: { status: 'resolved' }, source: 'system', actor: nil)

    expect(conversation.reload.status).to eq('resolved')
    expect(conversation.status_transitions.last).to have_attributes(reason: nil, source: 'system')
  end
end
