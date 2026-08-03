require 'rails_helper'

RSpec.describe Confirmations::DeliveryService do
  let(:account) { create(:account) }
  let(:user) { create(:user, :administrator, account: account) }

  it 'creates an outgoing native button message and records the selected strategy', :aggregate_failures do
    channel = create(:channel_telegram, account: account)
    conversation = create(:conversation, account: account, inbox: channel.inbox)
    request = create(:confirmation_request, account: account, conversation: conversation, contact: conversation.contact, inbox: conversation.inbox)

    message = described_class.new(confirmation_request: request, sender: user).perform

    expect(message).to be_persisted
    expect(message).to be_outgoing
    expect(message.content_type).to eq('input_select')
    expect(message.content_attributes).to include('confirmation_request_id' => request.id)
    expect(message.content_attributes).not_to have_key('confirmation_token')
    items = message.content_attributes['items']
    expect(items.pluck('title')).to eq(%w[Подтвердить Отменить Перенести])
    expect(items.map { |item| item['value'].bytesize }).to all(be <= 64)
    expect(items.map { |item| Confirmations::TelegramCallback.resolve(value: item['value'], account: account, conversation: conversation) }).to eq(
      [
        { confirmation_request: request, decision: 'confirmed' },
        { confirmation_request: request, decision: 'declined' },
        { confirmation_request: request, decision: 'reschedule_requested' }
      ]
    )
    expect(request.reload.delivery_strategy).to eq('native_buttons')
    expect(request.delivery_message).to eq(message)
  end

  it 'creates a WhatsApp template message outside the reply window and persists audit metadata' do
    template = {
      'name' => 'confirmation_buttons_ru',
      'status' => 'APPROVED',
      'category' => 'UTILITY',
      'language' => 'ru',
      'components' => [
        { 'type' => 'BODY', 'text' => '{{1}}\n{{2}}' },
        {
          'type' => 'BUTTONS',
          'buttons' => [
            { 'type' => 'QUICK_REPLY', 'text' => 'Подтвердить' },
            { 'type' => 'QUICK_REPLY', 'text' => 'Отменить' },
            { 'type' => 'QUICK_REPLY', 'text' => 'Перенести' }
          ]
        }
      ]
    }
    channel = create(
      :channel_whatsapp,
      account: account,
      provider: 'whatsapp_cloud',
      sync_templates: false,
      validate_provider_config: false,
      message_templates: [template]
    )
    conversation = create(:conversation, account: account, inbox: channel.inbox)
    create(:message, account: account, conversation: conversation, inbox: channel.inbox, message_type: :incoming, created_at: 2.days.ago)
    request = create(:confirmation_request, account: account, conversation: conversation, contact: conversation.contact, inbox: conversation.inbox)

    message = described_class.new(confirmation_request: request, sender: user).perform

    expect(message.additional_attributes['template_params']).to include('name' => 'confirmation_buttons_ru', 'language' => 'ru')
    expect(message.additional_attributes['delivery_policy']).to include('delivery_mode' => 'channel_template', 'requires_template' => true)
    expect(message.content_attributes['confirmation_request_id']).to eq(request.id)
    expect(request.reload.delivery_strategy).to eq('channel_template')
    expect(request.delivery_message).to eq(message)
  end
end
