require 'rails_helper'

RSpec.describe Confirmations::DeliveryService do
  let(:account) { create(:account) }
  let(:user) { create(:user, :administrator, account: account) }

  it 'creates an outgoing native button message and records the selected strategy' do
    channel = create(:channel_telegram, account: account)
    conversation = create(:conversation, account: account, inbox: channel.inbox)
    request = create(:confirmation_request, account: account, conversation: conversation, contact: conversation.contact, inbox: conversation.inbox)

    message = described_class.new(confirmation_request: request, sender: user).perform

    expect(message).to be_persisted
    expect(message).to be_outgoing
    expect(message.content_type).to eq('input_select')
    expect(message.content_attributes).to include('confirmation_request_id' => request.id)
    expect(message.content_attributes['items'].pluck('value')).to include("confirmation:#{request.token}:confirmed")
    expect(request.reload.delivery_strategy).to eq('native_buttons')
    expect(request.delivery_message).to eq(message)
  end
end
