require 'rails_helper'

RSpec.describe ConfirmationRequest do
  let(:account) { create(:account) }
  let(:conversation) { create(:conversation, account: account) }

  it 'defines native statuses and resolution sources for automatic, AI, manual, button and link flows' do
    expect(described_class::STATUSES).to contain_exactly('pending', 'confirmed', 'declined', 'reschedule_requested', 'expired')
    expect(described_class::RESOLUTION_SOURCES).to include('button', 'link', 'text', 'ai', 'manual', 'system')
  end

  it 'allows standalone confirmations without a subject' do
    request = described_class.new(
      account: account,
      conversation: conversation,
      contact: conversation.contact,
      inbox: conversation.inbox,
      title: 'Подтвердить согласие',
      body: 'Клиент подтверждает согласие?',
      token: SecureRandom.urlsafe_base64(24),
      expires_at: 1.hour.from_now
    )

    expect(request).to be_valid
  end

  it 'allows confirmations bound to a supported account-owned subject' do
    appointment = create(:scheduling_appointment, account: account, conversation: conversation, contact: conversation.contact)
    request = build(:confirmation_request, account: account, conversation: conversation, subject: appointment)

    expect(request).to be_valid
  end

  it 'rejects subjects from another account' do
    other_account = create(:account)
    appointment = create(:scheduling_appointment, account: other_account)
    request = build(:confirmation_request, account: account, conversation: conversation, subject: appointment)

    expect(request).not_to be_valid
    expect(request.errors[:subject]).to include('must belong to the current account')
  end

  it 'rejects conversation, contact and inbox records from another account' do
    other_conversation = create(:conversation)
    request = build(
      :confirmation_request,
      account: account,
      conversation: other_conversation,
      contact: other_conversation.contact,
      inbox: other_conversation.inbox
    )

    expect(request).not_to be_valid
    expect(request.errors[:conversation]).to include('must belong to the current account')
    expect(request.errors[:contact]).to include('must belong to the current account')
    expect(request.errors[:inbox]).to include('must belong to the current account')
  end
end
