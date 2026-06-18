require 'rails_helper'

RSpec.describe Whatsapp::TemplateRequestBuilderService do
  let(:asset_upload_service) { instance_double(Whatsapp::TemplateAssetUploadService) }

  describe '#call' do
    # rubocop:disable RSpec/ExampleLength
    it 'builds a supported request body for text, footer, and url buttons' do
      template_config = {
        name: 'order_update',
        language: 'en',
        category: 'utility',
        header_type: 'text',
        header_text: 'Order {{1}} update',
        header_examples: { '1' => '12345' },
        body_text: 'Hello {{1}}, your order is now {{2}}.',
        body_examples: { '1' => 'Alex', '2' => 'confirmed' },
        footer_text: 'Reply STOP to unsubscribe',
        buttons: [
          { type: 'QUICK_REPLY', text: 'Confirm' },
          {
            type: 'URL',
            text: 'Track order',
            url: 'https://example.com/orders/{{1}}',
            example: '12345'
          }
        ]
      }

      result = described_class.new(
        template_config: template_config,
        asset_upload_service: asset_upload_service
      ).call

      expect(result).to eq(
        name: 'order_update',
        language: 'en',
        category: 'UTILITY',
        components: [
          {
            type: 'BODY',
            text: 'Hello {{1}}, your order is now {{2}}.',
            example: { body_text: [%w[Alex confirmed]] }
          },
          {
            type: 'HEADER',
            format: 'TEXT',
            text: 'Order {{1}} update',
            example: { header_text: ['12345'] }
          },
          {
            type: 'FOOTER',
            text: 'Reply STOP to unsubscribe'
          },
          {
            type: 'BUTTONS',
            buttons: [
              { type: 'QUICK_REPLY', text: 'Confirm' },
              {
                type: 'URL',
                text: 'Track order',
                url: 'https://example.com/orders/{{1}}',
                example: ['12345']
              }
            ]
          }
        ]
      )
    end
    # rubocop:enable RSpec/ExampleLength

    it 'builds media headers with uploaded sample handles' do
      allow(asset_upload_service).to receive(:upload)
        .with(url: 'https://example.com/sample.pdf', media_type: 'document')
        .and_return('4:sample-handle')

      template_config = {
        name: 'invoice_ready',
        language: 'en',
        category: 'utility',
        header_type: 'document',
        sample_media_url: 'https://example.com/sample.pdf',
        body_text: 'Your invoice is ready.'
      }

      result = described_class.new(
        template_config: template_config,
        asset_upload_service: asset_upload_service
      ).call

      expect(result[:components]).to eq([
                                          {
                                            type: 'BODY',
                                            text: 'Your invoice is ready.'
                                          },
                                          {
                                            type: 'HEADER',
                                            format: 'DOCUMENT',
                                            example: { header_handle: ['4:sample-handle'] }
                                          }
                                        ])
    end

    it 'raises when placeholders are not sequential' do
      template_config = {
        name: 'broken_template',
        language: 'en',
        category: 'utility',
        body_text: 'Hello {{1}}, order {{3}}.'
      }

      expect do
        described_class.new(
          template_config: template_config,
          asset_upload_service: asset_upload_service
        ).call
      end.to raise_error(ArgumentError, 'Body text variables must be sequential without gaps')
    end

    it 'raises when a dynamic url button is missing a sample url' do
      template_config = {
        name: 'broken_button',
        language: 'en',
        category: 'utility',
        body_text: 'Order update',
        buttons: [
          {
            type: 'URL',
            text: 'Track',
            url: 'https://example.com/orders/{{1}}'
          }
        ]
      }

      expect do
        described_class.new(
          template_config: template_config,
          asset_upload_service: asset_upload_service
        ).call
      end.to raise_error(ArgumentError, 'Sample suffix is required for dynamic URL buttons')
    end

    it 'raises when body text starts or ends with a variable' do
      template_config = {
        name: 'broken_body',
        language: 'en',
        category: 'utility',
        body_text: '{{1}} order update'
      }

      expect do
        described_class.new(
          template_config: template_config,
          asset_upload_service: asset_upload_service
        ).call
      end.to raise_error(ArgumentError, 'Body text cannot start or end with a variable')
    end

    it 'normalizes full sample urls into suffix examples for dynamic url buttons' do
      template_config = {
        name: 'order_update',
        language: 'en',
        category: 'utility',
        body_text: 'Order update',
        buttons: [
          {
            type: 'URL',
            text: 'Track',
            url: 'https://example.com/orders/{{1}}',
            example: 'https://example.com/orders/12345'
          }
        ]
      }

      result = described_class.new(
        template_config: template_config,
        asset_upload_service: asset_upload_service
      ).call

      expect(result[:components].last[:buttons]).to eq([
                                                         {
                                                           type: 'URL',
                                                           text: 'Track',
                                                           url: 'https://example.com/orders/{{1}}',
                                                           example: ['12345']
                                                         }
                                                       ])
    end

    it 'raises when a dynamic url button variable is not the final suffix' do
      template_config = {
        name: 'broken_button_suffix',
        language: 'en',
        category: 'utility',
        body_text: 'Order update',
        buttons: [
          {
            type: 'URL',
            text: 'Track',
            url: 'https://example.com/orders/{{1}}/details',
            example: '12345'
          }
        ]
      }

      expect do
        described_class.new(
          template_config: template_config,
          asset_upload_service: asset_upload_service
        ).call
      end.to raise_error(ArgumentError, 'Dynamic URL button variable must be the final URL suffix')
    end

    it 'builds copy code and phone number buttons' do
      template_config = {
        name: 'support_offer',
        language: 'en',
        category: 'marketing',
        body_text: 'Use the code below or call us for help.',
        buttons: [
          {
            type: 'COPY_CODE',
            example: 'SAVE20'
          },
          {
            type: 'PHONE_NUMBER',
            text: 'Call support',
            phone_number: '+16505551234'
          }
        ]
      }

      result = described_class.new(
        template_config: template_config,
        asset_upload_service: asset_upload_service
      ).call

      expect(result[:components].last[:buttons]).to eq([
                                                         {
                                                           type: 'COPY_CODE',
                                                           example: 'SAVE20'
                                                         },
                                                         {
                                                           type: 'PHONE_NUMBER',
                                                           text: 'Call support',
                                                           phone_number: '+16505551234'
                                                         }
                                                       ])
    end

    it 'builds WhatsApp Flow template buttons' do
      template_config = {
        name: 'lead_flow',
        language: 'en',
        category: 'marketing',
        body_text: 'Please complete the lead form.',
        buttons: [
          {
            type: 'FLOW',
            text: 'Open form',
            flow_id: '1234567890'
          }
        ]
      }

      result = described_class.new(
        template_config: template_config,
        asset_upload_service: asset_upload_service
      ).call

      expect(result[:components].last[:buttons]).to eq([
                                                         {
                                                           type: 'FLOW',
                                                           text: 'Open form',
                                                           flow_id: '1234567890'
                                                         }
                                                       ])
    end

    it 'serializes WhatsApp Flow JSON as a string for Meta template creation' do
      flow_json = {
        version: '7.3',
        screens: [
          {
            id: 'LEAD_CAPTURE',
            title: 'Lead capture',
            terminal: true,
            layout: { type: 'SingleColumnLayout', children: [] }
          }
        ]
      }
      template_config = {
        name: 'lead_flow_json',
        language: 'en',
        category: 'marketing',
        body_text: 'Please complete the lead form.',
        buttons: [
          {
            type: 'FLOW',
            text: 'Open form',
            flow_json: flow_json
          }
        ]
      }

      result = described_class.new(
        template_config: template_config,
        asset_upload_service: asset_upload_service
      ).call

      button = result[:components].last[:buttons].first
      expect(button[:flow_json]).to be_a(String)
      expect(JSON.parse(button[:flow_json])).to include('version' => '7.3')
    end

    it 'rejects ambiguous WhatsApp Flow template button identifiers' do
      template_config = {
        name: 'lead_flow_ambiguous',
        language: 'en',
        category: 'marketing',
        body_text: 'Please complete the lead form.',
        buttons: [
          {
            type: 'FLOW',
            text: 'Open form',
            flow_id: '1234567890',
            flow_name: 'lead_flow'
          }
        ]
      }

      expect do
        described_class.new(
          template_config: template_config,
          asset_upload_service: asset_upload_service
        ).call
      end.to raise_error(ArgumentError, 'Flow button requires exactly one of flow_id, flow_name, or flow_json')
    end

    it 'raises when a copy code example exceeds the supported length' do
      template_config = {
        name: 'broken_copy_code',
        language: 'en',
        category: 'marketing',
        body_text: 'Special offer',
        buttons: [
          {
            type: 'COPY_CODE',
            example: 'SAVE20_WITH_TOO_LONG_CODE'
          }
        ]
      }

      expect do
        described_class.new(
          template_config: template_config,
          asset_upload_service: asset_upload_service
        ).call
      end.to raise_error(ArgumentError, 'Copy code example cannot exceed 15 characters')
    end

    it 'raises when a phone number button does not use E.164 format' do
      template_config = {
        name: 'broken_phone_button',
        language: 'en',
        category: 'utility',
        body_text: 'Contact support',
        buttons: [
          {
            type: 'PHONE_NUMBER',
            text: 'Call support',
            phone_number: '6505551234'
          }
        ]
      }

      expect do
        described_class.new(
          template_config: template_config,
          asset_upload_service: asset_upload_service
        ).call
      end.to raise_error(ArgumentError, 'Phone number buttons must use E.164 format')
    end
  end
end
