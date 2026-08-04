require 'rails_helper'

RSpec.describe Confirmations::TelegramTerminalFeedbackService do
  let(:account) { create(:account) }
  let(:channel) { create(:channel_telegram, account: account) }
  let(:conversation) do
    create(
      :conversation,
      account: account,
      inbox: channel.inbox,
      additional_attributes: { 'chat_id' => '123' }
    )
  end
  let(:message) do
    create(
      :message,
      account: account,
      inbox: channel.inbox,
      conversation: conversation,
      message_type: :outgoing,
      content_type: 'input_select',
      content: "Подтвердить запись\n\nВы придёте?",
      content_attributes: { 'items' => [{ 'title' => 'Подтвердить', 'value' => 'signed-value' }] },
      source_id: 'telegram-42'
    )
  end
  let(:confirmation_request) do
    create(
      :confirmation_request,
      account: account,
      conversation: conversation,
      contact: conversation.contact,
      inbox: channel.inbox,
      delivery_message: message,
      title: 'Подтвердить запись',
      body: 'Вы придёте?',
      status: 'confirmed',
      resolved_at: Time.current,
      resolution_source: 'button'
    )
  end

  it 'replaces Telegram buttons with a persisted terminal state' do
    expect(channel).to receive(:update_message).with(
      message: message,
      content: "Подтвердить запись\n\nВы придёте?\n\n✅ Подтверждено",
      reply_markup: { inline_keyboard: [] }.to_json
    )

    expect(described_class.new(confirmation_request: confirmation_request).perform).to be(true)

    message.reload
    expect(message).to be_text
    expect(message.content).to end_with('✅ Подтверждено')
    expect(message.content_attributes).to include(
      'items' => [],
      'edited' => true,
      'confirmation_status' => 'confirmed'
    )
    expect(message.content_attributes['confirmation_resolved_at']).to be_present
  end

  it 'does not alter local state when Telegram editing fails' do
    allow(channel).to receive(:update_message).and_raise(Timeout::Error, 'provider timeout')

    expect(described_class.new(confirmation_request: confirmation_request).perform).to be(false)
    expect(message.reload).to be_input_select
    expect(message.content_attributes['items']).to be_present
  end
end
