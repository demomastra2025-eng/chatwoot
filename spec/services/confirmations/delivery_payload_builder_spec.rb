require 'rails_helper'

RSpec.describe Confirmations::DeliveryPayloadBuilder do
  let(:account) { create(:account) }

  before do
    stub_request(:post, /graph.facebook.com/)
  end

  def request_for_channel(channel, last_incoming_at: nil, metadata: {})
    inbox = channel.inbox || create(:inbox, account: account, channel: channel)
    conversation = create(:conversation, account: account, inbox: inbox)
    if last_incoming_at.present?
      create(:message, account: account, conversation: conversation, inbox: inbox, message_type: :incoming, created_at: last_incoming_at)
    end
    create(:confirmation_request, account: account, conversation: conversation, contact: conversation.contact, inbox: inbox, metadata: metadata)
  end

  def whatsapp_confirmation_template
    {
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
  end

  def unrelated_whatsapp_quick_reply_template
    whatsapp_confirmation_template.merge('name' => 'shipping_status_buttons')
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
    request = request_for_channel(create(:channel_sms, account: account))

    payload = described_class.new(request).message_params

    expect(payload[:delivery_strategy]).to eq('text_reply')
    expect(payload[:content_type]).to eq('text')
    expect(payload[:content]).to include('Ответьте')
    expect(payload[:content]).to include(request.token)
  end

  it 'uses WhatsApp interactive buttons while the 24-hour reply window is open' do
    channel = create(:channel_whatsapp, account: account, provider: 'whatsapp_cloud', sync_templates: false, validate_provider_config: false)
    request = request_for_channel(channel, last_incoming_at: 2.hours.ago)

    payload = described_class.new(request).message_params

    expect(payload[:delivery_strategy]).to eq('native_buttons')
    expect(payload[:content_type]).to eq('input_select')
    expect(payload.dig(:content_attributes, :confirmation_request_id)).to eq(request.id)
    expect(payload.dig(:content_attributes, :confirmation_strategy)).to eq('native_buttons')
    expect(payload[:delivery_policy]).to include(
      delivery_mode: 'free_text',
      content_kind: 'free_text',
      reply_window_open: true
    )
  end

  it 'keeps non-Cloud WhatsApp providers on generic text reply delivery' do
    channel = create(:channel_whatsapp, account: account, provider: 'default', sync_templates: false, validate_provider_config: false)
    request = request_for_channel(channel, last_incoming_at: 2.hours.ago)

    payload = described_class.new(request).message_params

    expect(payload[:delivery_strategy]).to eq('text_reply')
    expect(payload[:content_type]).to eq('text')
    expect(payload[:content]).to include('Ответьте')
  end

  it 'uses an approved WhatsApp template with quick-reply buttons when the 24-hour reply window is closed' do
    channel = create(
      :channel_whatsapp,
      account: account,
      provider: 'whatsapp_cloud',
      sync_templates: false,
      validate_provider_config: false,
      message_templates: [whatsapp_confirmation_template]
    )
    request = request_for_channel(channel, last_incoming_at: 2.days.ago)

    payload = described_class.new(request).message_params

    expect(payload[:delivery_strategy]).to eq('channel_template')
    expect(payload[:content_type]).to eq('text')
    expect(payload[:template_params]).to include(
      'name' => 'confirmation_buttons_ru',
      'language' => 'ru'
    )
    expect(payload.dig(:template_params, 'processed_params', 'body')).to eq(
      '1' => request.title,
      '2' => request.body
    )
    expect(payload.dig(:content_attributes, :items).pluck(:value)).to include("confirmation:#{request.token}:confirmed")
    expect(payload[:delivery_policy]).to include(
      delivery_mode: 'channel_template',
      content_kind: 'channel_template',
      requires_template: true,
      reply_window_open: false
    )
  end

  it 'fails fast with a manual-required strategy when WhatsApp needs a template but no approved confirmation template is available' do
    channel = create(:channel_whatsapp, account: account, provider: 'whatsapp_cloud', sync_templates: false, validate_provider_config: false)
    request = request_for_channel(channel, last_incoming_at: 2.days.ago)

    payload = described_class.new(request).message_params

    expect(payload[:delivery_strategy]).to eq('manual_required')
    expect(payload[:private]).to be(true)
    expect(payload[:content]).to include('не найден approved WhatsApp template')
    expect(payload[:delivery_policy]).to include(
      delivery_mode: nil,
      requires_template: true,
      reply_window_open: false
    )
  end

  it 'does not use unrelated approved quick-reply templates for confirmation delivery' do
    channel = create(
      :channel_whatsapp,
      account: account,
      provider: 'whatsapp_cloud',
      sync_templates: false,
      validate_provider_config: false,
      message_templates: [unrelated_whatsapp_quick_reply_template]
    )
    request = request_for_channel(channel, last_incoming_at: 2.days.ago)

    payload = described_class.new(request).message_params

    expect(payload[:delivery_strategy]).to eq('manual_required')
    expect(payload).not_to have_key(:template_params)
  end
end
