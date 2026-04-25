require 'rails_helper'

RSpec.describe Confirmations::CreateService do
  let(:account) { create(:account) }
  let(:user) { create(:user, :administrator, account: account) }
  let(:conversation) { create(:conversation, account: account) }

  let(:standalone_request) do
    described_class.new(
      account: account,
      conversation: conversation,
      title: 'Подтвердить заявку',
      body: 'Подтверждаете заявку?',
      expires_at: 2.hours.from_now,
      requester: user,
      metadata: { 'purpose' => 'standalone' }
    ).perform
  end

  it 'creates a standalone pending confirmation and infers conversation context' do
    expect(standalone_request).to be_persisted
    expect(standalone_request).to be_pending
    expect(standalone_request.subject).to be_nil
    expect(standalone_request.contact).to eq(conversation.contact)
    expect(standalone_request.inbox).to eq(conversation.inbox)
  end

  it 'stores requester, token and metadata for standalone confirmations' do
    expect(standalone_request.requested_by).to eq(user)
    expect(standalone_request.token).to be_present
    expect(standalone_request.metadata).to include('purpose' => 'standalone')
  end

  it 'creates an appointment-bound confirmation for the same account' do
    appointment = create(:scheduling_appointment, account: account, conversation: conversation, contact: conversation.contact)

    request = described_class.new(
      account: account,
      conversation: conversation,
      subject: appointment,
      title: 'Подтвердить прием',
      body: 'Вы подтверждаете запись?',
      requester: user
    ).perform

    expect(request.subject).to eq(appointment)
    expect(request.conversation).to eq(conversation)
    expect(request.contact).to eq(conversation.contact)
  end

  it 'rejects a subject from another account before persistence' do
    other_account = create(:account)
    appointment = create(:scheduling_appointment, account: other_account)

    expect do
      described_class.new(
        account: account,
        conversation: conversation,
        subject: appointment,
        title: 'Подтвердить прием',
        body: 'Вы подтверждаете запись?'
      ).perform
    end.to raise_error(ArgumentError, /subject must belong to the current account/)

    expect(ConfirmationRequest.count).to eq(0)
  end

  it 'returns the existing request when the idempotency key is reused in the same account' do
    first = described_class.new(
      account: account,
      conversation: conversation,
      title: 'Подтвердить заявку',
      body: 'Подтверждаете?',
      idempotency_key: 'confirm-123'
    ).perform

    second = described_class.new(
      account: account,
      conversation: conversation,
      title: 'Подтвердить заявку еще раз',
      body: 'Другой текст не должен создать дубль',
      idempotency_key: 'confirm-123'
    ).perform

    expect(second).to eq(first)
    expect(ConfirmationRequest.where(account: account).count).to eq(1)
  end
end
