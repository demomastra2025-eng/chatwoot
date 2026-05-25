require 'rails_helper'

RSpec.describe Whatsapp::ReauthorizationService do
  let(:account) { create(:account) }
  let(:channel) do
    create(
      :channel_whatsapp,
      account: account,
      provider: 'whatsapp_cloud',
      provider_config: existing_provider_config,
      validate_provider_config: false,
      sync_templates: false
    )
  end
  let(:inbox) { channel.inbox }
  let(:existing_provider_config) { { 'source' => 'embedded_signup' } }
  let(:phone_info) do
    {
      phone_number: channel.phone_number,
      business_name: 'Reauthorized WhatsApp',
      calling_capable: true,
      calling_capabilities: ['CALLING']
    }
  end

  before do
    setup_service = instance_double(Whatsapp::WebhookSetupService)
    allow(Whatsapp::WebhookSetupService).to receive(:new).and_return(setup_service)
    allow(setup_service).to receive(:perform)
    stub_request(:get, 'https://graph.facebook.com/v22.0/waba-1/message_templates')
      .to_return(status: 200, body: { data: [] }.to_json, headers: { 'Content-Type' => 'application/json' })
  end

  it 'enables WhatsApp Calling by default when capability is present and no manual toggle exists' do
    described_class.new(
      account: account,
      inbox_id: inbox.id,
      phone_number_id: 'phone-1',
      business_id: 'waba-1'
    ).perform('new-token', phone_info)

    expect(channel.reload.provider_config).to include(
      'calling_capable' => true,
      'calling_enabled' => true,
      'calling_capabilities' => ['CALLING']
    )
  end

  context 'when calling was manually disabled' do
    let(:existing_provider_config) { { 'source' => 'embedded_signup', 'calling_enabled' => false } }

    it 'preserves the explicit disable while refreshing capability metadata' do
      described_class.new(
        account: account,
        inbox_id: inbox.id,
        phone_number_id: 'phone-1',
        business_id: 'waba-1'
      ).perform('new-token', phone_info)

      expect(channel.reload.provider_config).to include(
        'calling_capable' => true,
        'calling_enabled' => false,
        'calling_capabilities' => ['CALLING']
      )
    end
  end

  context 'when the existing channel is flagged for reauthorization' do
    let(:existing_provider_config) do
      {
        'source' => 'embedded_signup',
        'authorization_status' => 'reauthorization_required',
        'authorization_error' => {
          'code' => 190,
          'message' => 'Expired token',
          'recorded_at' => 1.hour.ago.iso8601
        }
      }
    end

    it 'refreshes credentials on the same inbox/channel and preserves conversation data' do
      conversation = create(:conversation, account: account, inbox: inbox)
      message = create(:message, account: account, inbox: inbox, conversation: conversation, content: 'Preserve me')

      channel.prompt_reauthorization!

      result = described_class.new(
        account: account,
        inbox_id: inbox.id,
        phone_number_id: 'phone-1',
        business_id: 'waba-1'
      ).perform('new-token', phone_info)

      expect(result.id).to eq(channel.id)
      expect(inbox.reload.channel).to eq(channel)
      expect(conversation.reload.inbox).to eq(inbox)
      expect(message.reload.conversation).to eq(conversation)
      expect(channel.reload.reauthorization_required?).to be(false)
      expect(channel.provider_config).to include(
        'api_key' => 'new-token',
        'phone_number_id' => 'phone-1',
        'business_account_id' => 'waba-1'
      )
      expect(channel.provider_config).not_to include('authorization_status')
      expect(channel.provider_config).not_to include('authorization_error')
    end
  end
end
