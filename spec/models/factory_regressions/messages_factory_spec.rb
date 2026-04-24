require 'rails_helper'

RSpec.describe 'message factory' do
  it 'inherits account and inbox from a provided conversation' do
    conversation = create(:conversation)

    message = build(:message, conversation: conversation)

    expect(message.account).to eq(conversation.account)
    expect(message.inbox).to eq(conversation.inbox)
    expect(message.conversation).to eq(conversation)
  end

  it 'inherits account from a provided inbox when conversation is absent' do
    inbox = create(:inbox)

    message = build(:message, inbox: inbox, conversation: nil)

    expect(message.account).to eq(inbox.account)
    expect(message.inbox).to eq(inbox)
    expect(message.conversation.account).to eq(inbox.account)
  end
end
