require 'rails_helper'

RSpec.describe 'conversation factory' do
  it 'inherits the account from a provided inbox' do
    inbox = create(:inbox)

    conversation = build(:conversation, inbox: inbox)

    expect(conversation.account).to eq(inbox.account)
    expect(conversation.contact.account).to eq(inbox.account)
    expect(conversation.contact_inbox.inbox).to eq(inbox)
  end

  it 'inherits the account from a provided contact when inbox is absent' do
    contact = create(:contact)

    conversation = build(:conversation, contact: contact, inbox: nil)

    expect(conversation.account).to eq(contact.account)
    expect(conversation.contact).to eq(contact)
    expect(conversation.inbox.account).to eq(contact.account)
  end
end
