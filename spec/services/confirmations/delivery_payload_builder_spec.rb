require 'rails_helper'

RSpec.describe Confirmations::DeliveryPayloadBuilder do
  let(:account) { create(:account) }

  before do
    stub_request(:post, /graph.facebook.com/)
  end

  def request_for_channel(channel)
    inbox = channel.inbox || create(:inbox, account: account, channel: channel)
    conversation = create(:conversation, account: account, inbox: inbox)
    create(:confirmation_request, account: account, conversation: conversation, contact: conversation.contact, inbox: inbox)
  end

  it 'uses native input_select buttons for Telegram bot channels' do
    channel = create(:channel_telegram, account: account)
    request = request_for_channel(channel)

    payload = described_class.new(request).message_params

    expect(payload[:delivery_strategy]).to eq('native_buttons')
    expect(payload[:content_type]).to eq('input_select')
    expect(payload.dig(:content_attributes, :confirmation_request_id)).to eq(request.id)
    expect(payload.dig(:content_attributes, :items)).to contain_exactly(
      include(title: 'Подтвердить', value: "confirmation:#{request.token}:confirmed"),
      include(title: 'Отменить', value: "confirmation:#{request.token}:declined"),
      include(title: 'Перенести', value: "confirmation:#{request.token}:reschedule_requested")
    )
  end

  it 'uses native buttons for LINE and Facebook quick-reply capable channels' do
    line_request = request_for_channel(create(:channel_line, account: account))
    facebook_request = request_for_channel(create(:channel_facebook_page, account: account))

    expect(described_class.new(line_request).message_params[:delivery_strategy]).to eq('native_buttons')
    expect(described_class.new(facebook_request).message_params[:delivery_strategy]).to eq('native_buttons')
  end

  it 'uses link buttons for email channels' do
    request = request_for_channel(create(:channel_email, account: account))

    payload = described_class.new(request).message_params

    expect(payload[:delivery_strategy]).to eq('link_buttons')
    expect(payload[:content_type]).to eq('text')
    expect(payload[:content]).to include(request.token)
    expect(payload[:content]).to include('/public/confirmation_requests/')
  end

  it 'falls back to text replies with links when native buttons are not available' do
    request = request_for_channel(create(:channel_whatsapp, account: account, sync_templates: false, validate_provider_config: false))

    payload = described_class.new(request).message_params

    expect(payload[:delivery_strategy]).to eq('text_reply')
    expect(payload[:content_type]).to eq('text')
    expect(payload[:content]).to include('Ответьте')
    expect(payload[:content]).to include(request.token)
  end
end
