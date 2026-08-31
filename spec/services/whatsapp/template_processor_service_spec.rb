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
  end
end
