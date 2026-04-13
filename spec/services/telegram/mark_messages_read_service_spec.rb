require 'rails_helper'

RSpec.describe Telegram::MarkMessagesReadService do
  it 'marks unread incoming telegram business messages as read through the provider' do
    channel = create(:channel_telegram)
    conversation = create(
      :conversation,
      account: channel.account,
      inbox: channel.inbox,
      additional_attributes: { 'chat_id' => '123', 'business_connection_id' => 'biz-1' }
    )
    incoming_message = create(
      :message,
      account: channel.account,
      inbox: channel.inbox,
      conversation: conversation,
      message_type: :incoming,
      source_id: '55'
    )

    expect(channel).to receive(:mark_message_read).with(message: incoming_message).and_return(true)

    result = described_class.new(
      conversation: conversation,
      messages: [incoming_message]
    ).perform

    expect(result).to eq(true)
  end

  it 'does not sync non-business telegram conversations' do
    channel = create(:channel_telegram)
    conversation = create(
      :conversation,
      account: channel.account,
      inbox: channel.inbox,
      additional_attributes: { 'chat_id' => '123' }
    )
    incoming_message = create(
      :message,
      account: channel.account,
      inbox: channel.inbox,
      conversation: conversation,
      message_type: :incoming,
      source_id: '55'
    )

    expect(channel).not_to receive(:mark_message_read)

    result = described_class.new(
      conversation: conversation,
      messages: [incoming_message]
    ).perform

    expect(result).to eq(false)
  end
end
