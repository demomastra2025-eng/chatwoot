# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Confirmations::IncomingReplyResolver do
  let(:message) { create(:message, message_type: :incoming) }

  it 'routes callback payloads to the Telegram callback resolver' do
    callback_resolver = instance_double(Confirmations::TelegramReplyResolver, perform: :resolved)

    expect(Confirmations::TelegramReplyResolver).to receive(:new)
      .with(
        conversation: message.conversation,
        actor: message.sender,
        inbox: message.inbox,
        callback_value: 'cfm:1:c:signature'
      )
      .and_return(callback_resolver)

    expect(described_class.new(message: message, callback_value: 'cfm:1:c:signature').perform).to eq(:resolved)
  end

  it 'routes text replies with the full inbound resolver context' do
    text_resolver = instance_double(Confirmations::InboundTextResolver, perform: { handled: false })

    expect(Confirmations::InboundTextResolver).to receive(:new)
      .with(account: message.account, conversation: message.conversation, message: message)
      .and_return(text_resolver)

    expect(described_class.new(message: message).perform).to eq(handled: false)
  end
end
