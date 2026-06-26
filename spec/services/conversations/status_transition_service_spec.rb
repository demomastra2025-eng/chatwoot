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
