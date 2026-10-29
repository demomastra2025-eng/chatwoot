require 'rails_helper'

RSpec.describe Whatsapp::TemplateProcessorService do
  let(:channel) { create(:channel_whatsapp, sync_templates: false, validate_provider_config: false) }

  describe '#call' do
    let(:carousel_template) do
      {
        'name' => 'carousel_template',
        'language' => 'en_US',
        'status' => 'APPROVED',
        'components' => [{
          'type' => 'CAROUSEL',
          'cards' => [{
            'components' => [
              { 'type' => 'HEADER', 'format' => 'IMAGE' },
              { 'type' => 'BODY', 'text' => 'Product {{1}}' },
              {
                'type' => 'BUTTONS',
                'buttons' => [
                  { 'type' => 'QUICK_REPLY' },
                  { 'type' => 'URL', 'url' => 'https://example.com/{{1}}' }
                ]
              }
            ]
          }]
        }]
      }
    end

    it 'does not raise when the channel template cache is empty' do
      channel.update!(message_templates: nil)

      template_params = {
        'name' => 'sample_template',
        'namespace' => 'namespace_2',
        'language' => 'en_US',
        'processed_params' => { 'body' => { 'ticket_id' => '123' } }
      }

      service = described_class.new(channel: channel, template_params: template_params)

      expect { service.call }.not_to raise_error
      expect(service.call).to eq(['sample_template', 'namespace_2', 'en_US', nil])
    end

    it 'matches templates by namespace when the provider returns duplicate names' do
      channel.update!(
        message_templates: [
          {
            'name' => 'sample_template',
            'namespace' => 'namespace_1',
            'language' => 'en_US',
            'status' => 'APPROVED',
            'components' => [{ 'type' => 'BODY', 'text' => 'Hello {{1}}' }]
          },
          {
            'name' => 'sample_template',
            'namespace' => 'namespace_2',
            'language' => 'en_US',
            'status' => 'APPROVED',
            'parameter_format' => 'NAMED',
            'components' => [{ 'type' => 'BODY', 'text' => 'Hello {{ticket_id}}' }]
          }
        ]
      )

      template_params = {
        'name' => 'sample_template',
        'namespace' => 'namespace_2',
        'language' => 'en_US',
        'processed_params' => { 'body' => { 'ticket_id' => '123' } }
      }

      service = described_class.new(channel: channel, template_params: template_params)
      _, _, _, processed_params = service.call

      expect(processed_params).to eq(
        [
          {
            type: 'body',
            parameters: [{ type: 'text', parameter_name: 'ticket_id', text: '123' }]
          }
        ]
      )
    end

    it 'builds authentication template body and copy-code button from one OTP value' do
      channel.update!(
        message_templates: [
          {
            'name' => 'auth_template',
            'language' => 'en_US',
            'status' => 'APPROVED',
            'category' => 'AUTHENTICATION',
            'components' => [
              { 'type' => 'BODY', 'text' => 'Your code is {{1}}' },
              { 'type' => 'BUTTONS', 'buttons' => [{ 'type' => 'URL' }] }
            ]
          }
        ]
      )

      template_params = {
        'name' => 'auth_template',
        'language' => 'en_US',
        'processed_params' => { 'body' => { '1' => '123456' } }
      }

      service = described_class.new(channel: channel, template_params: template_params)

      expect(service.call).to eq(
        [
          'auth_template', nil, 'en_US',
          [
            { type: 'body', parameters: [{ type: 'text', text: '123456' }] },
            { type: 'button', sub_type: 'url', index: 0, parameters: [{ type: 'text', text: '123456' }] }
          ]
        ]
      )
    end

    it 'builds an optional catalog thumbnail action parameter' do
      channel.update!(
        message_templates: [
          {
            'name' => 'catalog_template',
            'language' => 'en_US',
            'status' => 'APPROVED',
            'category' => 'MARKETING',
            'components' => [
              { 'type' => 'BODY', 'text' => 'Browse our catalog' },
              { 'type' => 'BUTTONS', 'buttons' => [{ 'type' => 'CATALOG', 'text' => 'View catalog' }] }
            ]
          }
        ]
      )

      service = described_class.new(
        channel: channel,
        template_params: {
          'name' => 'catalog_template',
          'language' => 'en_US',
          'processed_params' => { 'catalog' => { 'thumbnail_product_retailer_id' => 'sku-42' } }
        }
      )

      expect(service.call).to eq(
        [
          'catalog_template', nil, 'en_US',
          [{
            type: 'button', sub_type: 'CATALOG', index: 0,
            parameters: [{ type: 'action', action: { thumbnail_product_retailer_id: 'sku-42' } }]
          }]
        ]
      )
    end

    it 'auto-injects a signed olf1 flow_token action parameter for templates with a FLOW button' do
      account = channel.account
      contact = create(:contact, account: account, name: 'Асет')
      conversation = create(:conversation, account: account, inbox: channel.inbox, contact: contact)
      message = create(:message, account: account, inbox: channel.inbox, conversation: conversation, message_type: 'outgoing')

      channel.update!(
        provider_config: channel.provider_config.merge(
          'whatsapp_flows' => {
            'flows' => [{ 'id' => 'flow_booking_99', 'kind' => 'booking', 'locale' => 'ru' }]
          }
        ),
        message_templates: [
          {
            'name' => 'booking_invite',
            'language' => 'ru',
            'status' => 'APPROVED',
            'category' => 'UTILITY',
            'components' => [
              { 'type' => 'BODY', 'text' => 'Запишитесь онлайн в 1 клик' },
              {
                'type' => 'BUTTONS',
                'buttons' => [{ 'type' => 'FLOW', 'text' => 'Записаться', 'flow_id' => 'flow_booking_99' }]
              }
            ]
          }
        ]
      )

      service = described_class.new(
        channel: channel,
        template_params: { 'name' => 'booking_invite', 'language' => 'ru', 'processed_params' => {} },
        message: message
      )
      _, _, _, components = service.call

      flow_button = components.find { |comp| comp[:type] == 'button' && comp[:sub_type] == 'flow' }
      expect(flow_button).to be_present
      expect(flow_button[:index]).to eq(0)

      generated_token = flow_button.dig(:parameters, 0, :action, :flow_token)
      expect(generated_token).to start_with('olf1.')
      verified = Whatsapp::Flows::TokenService.verify_flow_token(generated_token, channel: channel)
      expect(verified[:valid]).to be(true)
      expect(verified[:payload]).to include(
        channel_id: channel.id,
        conversation_id: conversation.id,
        contact_id: contact.id,
        kind: 'booking',
        locale: 'ru'
      )
    end

    it 'builds nested carousel card components from exact cached template structure' do
      channel.update!(message_templates: [carousel_template])

      template_params = {
        'name' => 'carousel_template',
        'language' => 'en_US',
        'processed_params' => {
          'carousel' => {
            'cards' => [{
              'card_index' => 0,
              'header' => { 'media_id' => 'meta-media-1', 'media_type' => 'image' },
              'body' => { '1' => 'One' },
              'buttons' => [
                { 'index' => 0, 'type' => 'quick_reply', 'parameter' => 'product-one' },
                { 'index' => 1, 'type' => 'url', 'parameter' => 'one' }
              ]
            }]
          }
        }
      }

      service = described_class.new(channel: channel, template_params: template_params)

      expect(service.call).to eq(
        [
          'carousel_template', nil, 'en_US',
          [{
            type: 'carousel',
            cards: [{
              card_index: 0,
              components: [
                { type: 'header', parameters: [{ type: 'image', image: { id: 'meta-media-1' } }] },
                { type: 'body', parameters: [{ type: 'text', text: 'One' }] },
                { type: 'button', sub_type: 'quick_reply', index: 0, parameters: [{ type: 'payload', payload: 'product-one' }] },
                { type: 'button', sub_type: 'url', index: 1, parameters: [{ type: 'text', text: 'one' }] }
              ]
            }]
          }]
        ]
      )
    end

    it 'uploads and uses the file retained by the carousel template author' do
      channel.update!(provider: 'whatsapp_cloud')
      channel.update!(message_templates: [carousel_template])
      source = channel.template_media_sources.create!(
        template_name: 'carousel_template',
        language: 'en_us',
        card_index: 0,
        media_type: 'image',
        source_url: 'https://cdn.example.com/product.jpg'
      )
      uploader = instance_double(Whatsapp::TemplateSendMediaUploadService)
      allow(Whatsapp::TemplateSendMediaUploadService).to receive(:new)
        .with(whatsapp_channel: channel)
        .and_return(uploader)
      expect(uploader).to receive(:call).with(
        media_type: 'image',
        source: source,
        temporary_blob_signed_id: nil
      ).and_return('meta-media-from-author-file')

      service = described_class.new(
        channel: channel,
        template_params: {
          'name' => 'carousel_template',
          'language' => 'en_US',
          'processed_params' => {
            'carousel' => {
              'cards' => [{
                'card_index' => 0,
                'header' => { 'media_type' => 'image', 'has_template_media' => true },
                'body' => { '1' => 'One' },
                'buttons' => [
                  { 'index' => 0, 'type' => 'quick_reply', 'parameter' => 'product-one' },
                  { 'index' => 1, 'type' => 'url', 'parameter' => 'one' }
                ]
              }]
            }
          }
        }
      )

      _, _, _, components = service.call
      expect(components.dig(0, :cards, 0, :components, 0, :parameters, 0, :image, :id))
        .to eq('meta-media-from-author-file')
    end

    it 'requires a manual Meta media ID after switching retained media to a legacy provider' do
      channel.update!(message_templates: [carousel_template])
      channel.template_media_sources.create!(
        template_name: 'carousel_template',
        language: 'en_us',
        card_index: 0,
        media_type: 'image',
        source_url: 'https://cdn.example.com/product.jpg'
      )
      service = described_class.new(
        channel: channel,
        template_params: {
          'name' => 'carousel_template',
          'language' => 'en_US',
          'processed_params' => {
            'carousel' => {
              'cards' => [{ 'card_index' => 0, 'header' => {}, 'body' => { '1' => 'One' }, 'buttons' => [] }]
            }
          }
        }
      )

      expect { service.call }.to raise_error(ArgumentError, 'Carousel card 1 Meta media ID is required')
    end

    it 'renders field references in processed template params before building WhatsApp Cloud components' do
      account = channel.account
      contact = create(:contact, account: account, name: 'Ахан')
      conversation = create(:conversation, account: account, inbox: channel.inbox, contact: contact)
      message = create(
        :message,
        account: account,
        inbox: channel.inbox,
        conversation: conversation,
        message_type: 'outgoing'
      )
      channel.update!(
        message_templates: [
          {
            'name' => 'sample_template',
            'language' => 'en_US',
            'status' => 'APPROVED',
            'components' => [{ 'type' => 'BODY', 'text' => 'Hello {{1}}' }]
          }
        ]
      )

      template_params = {
        'name' => 'sample_template',
        'language' => 'en_US',
        'processed_params' => { 'body' => { '1' => '[Имя](field://contact.name)' } }
      }

      service = described_class.new(channel: channel, template_params: template_params, message: message)
      _, _, _, processed_params = service.call

      expect(processed_params).to eq(
        [
          {
            type: 'body',
            parameters: [{ type: 'text', text: 'Ахан' }]
          }
        ]
      )
    end

    it 'auto-signs explicit flow button parameters when flow_token is omitted or unused' do
      contact = create(:contact, account: channel.account, name: 'Алия')
      conversation = create(:conversation, account: channel.account, inbox: channel.inbox, contact: contact)
      message = create(
        :message, account: channel.account, inbox: channel.inbox, conversation: conversation, message_type: 'outgoing'
      )
      channel.update!(
        message_templates: [{
          'name' => 'flow_booking_tpl',
          'language' => 'ru',
          'status' => 'APPROVED',
          'components' => [
            { 'type' => 'BODY', 'text' => 'Запишитесь онлайн' },
            { 'type' => 'BUTTONS', 'buttons' => [{ 'type' => 'FLOW', 'text' => 'Записаться', 'flow_id' => 'flow_1' }] }
          ]
        }]
      )

      _, _, _, components = described_class.new(
        channel: channel,
        message: message,
        template_params: {
          'name' => 'flow_booking_tpl',
          'language' => 'ru',
          'processed_params' => {
            'buttons' => [{ 'type' => 'flow', 'action' => { 'flow_action_data' => { 'service_id' => '5' } } }]
          }
        }
      ).call

      flow_btn = components.find { |c| c[:type] == 'button' && c[:sub_type] == 'flow' }
      action = flow_btn.dig(:parameters, 0, :action)
      expect(action[:flow_action_data]).to eq(service_id: '5')
      expect(action[:flow_token]).to start_with('olf1.')
    end
  end
end
