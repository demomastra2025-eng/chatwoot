require 'rails_helper'

RSpec.describe Confirmations::InboundTextResolver do
  let(:account) { create(:account) }
  let(:conversation) { create(:conversation, account: account) }
  let!(:request) do
    create(
      :confirmation_request,
      account: account,
      conversation: conversation,
      contact: conversation.contact,
      inbox: conversation.inbox
    )
  end

  it 'automatically confirms a single pending request from clear Russian text' do
    message = create(:message, account: account, conversation: conversation, inbox: conversation.inbox, content: 'Да, подтверждаю')

    result = described_class.new(account: account, conversation: conversation, message: message).perform

    expect(result).to include(handled: true, decision: 'confirmed')
    expect(result[:confidence]).to be >= 0.9
    expect(request.reload).to be_confirmed
    expect(request.resolution_source).to eq('text')
    expect(request.resolved_message).to eq(message)
  end

  it 'declines a pending request from clear negative text' do
    message = create(:message, account: account, conversation: conversation, inbox: conversation.inbox, content: 'Нет, отмените')

    result = described_class.new(account: account, conversation: conversation, message: message).perform

    expect(result).to include(handled: true, decision: 'declined')
    expect(request.reload).to be_declined
  end

  it 'marks reschedule_requested from transfer/reschedule text' do
    message = create(:message, account: account, conversation: conversation, inbox: conversation.inbox, content: 'Можно перенести на другое время?')

    result = described_class.new(account: account, conversation: conversation, message: message).perform

    expect(result).to include(handled: true, decision: 'reschedule_requested')
    expect(request.reload).to be_reschedule_requested
  end

  it 'does not resolve ambiguous text and leaves the request pending for AI/manual clarification' do
    message = create(:message, account: account, conversation: conversation, inbox: conversation.inbox, content: 'Наверное посмотрим')

    result = described_class.new(account: account, conversation: conversation, message: message).perform

    expect(result).to include(handled: false, reason: 'ambiguous')
    expect(request.reload).to be_pending
  end

  it 'does not leak or resolve pending requests from another account' do
    other_account = create(:account)
    other_conversation = create(:conversation, account: other_account)
    other_request = create(:confirmation_request, account: other_account, conversation: other_conversation)
    message = create(:message, account: account, conversation: conversation, inbox: conversation.inbox, content: 'Да')
    request.destroy!

    result = described_class.new(account: account, conversation: conversation, message: message).perform

    expect(result).to include(handled: false, reason: 'no_pending_request')
    expect(other_request.reload).to be_pending
  end
end
