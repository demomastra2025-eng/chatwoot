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

    it 'builds media headers from an uploaded OneLink file' do
      allow(asset_upload_service).to receive(:upload)
      allow(asset_upload_service).to receive(:upload_blob)
        .with(blob_signed_id: 'signed-media-blob', media_type: 'image')
        .and_return('4:uploaded-file-handle')

      result = described_class.new(
        template_config: {
          name: 'photo_ready',
          language: 'en',
          category: 'utility',
          header_type: 'image',
          sample_media_blob_id: 'signed-media-blob',
          body_text: 'Your photo is ready.'
        },
        asset_upload_service: asset_upload_service
      ).call

      expect(result[:components].second).to eq(
        type: 'HEADER',
        format: 'IMAGE',
        example: { header_handle: ['4:uploaded-file-handle'] }
      )
      expect(asset_upload_service).not_to have_received(:upload)
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

    it 'builds a preset copy-code authentication template' do
      result = described_class.new(
        template_config: {
          name: 'login_code',
          language: 'en_US',
          category: 'authentication',
          add_security_recommendation: true,
          code_expiration_minutes: 10
        },
        asset_upload_service: asset_upload_service
      ).call

      expect(result).to eq(
        name: 'login_code',
        language: 'en_US',
        category: 'AUTHENTICATION',
        components: [
          { type: 'BODY', add_security_recommendation: true },
          { type: 'FOOTER', code_expiration_minutes: 10 },
          { type: 'BUTTONS', buttons: [{ type: 'OTP', otp_type: 'COPY_CODE' }] }
        ]
      )
    end

    it 'rejects custom components for authentication templates' do
      expect do
        described_class.new(
          template_config: {
            name: 'broken_login_code',
            language: 'en_US',
            category: 'authentication',
            body_text: 'Custom OTP body'
          },
          asset_upload_service: asset_upload_service
        ).call
      end.to raise_error(
        ArgumentError,
        'Authentication templates use preset text and an OTP button; custom components are not supported'
      )
    end

    it 'builds the fixed catalog button for marketing templates' do
      result = described_class.new(
        template_config: {
          name: 'browse_catalog',
          language: 'en_US',
          category: 'marketing',
          body_text: 'Browse our latest products.',
          buttons: [{ type: 'CATALOG', text: 'View catalog' }]
        },
        asset_upload_service: asset_upload_service
      ).call

      expect(result[:components].last).to eq(
        type: 'BUTTONS',
        buttons: [{ type: 'CATALOG', text: 'View catalog' }]
      )
    end

    it 'rejects catalog buttons outside marketing templates' do
      expect do
        described_class.new(
          template_config: {
            name: 'utility_catalog',
            language: 'en_US',
            category: 'utility',
            body_text: 'Browse products.',
            buttons: [{ type: 'CATALOG', text: 'View catalog' }]
          },
          asset_upload_service: asset_upload_service
        ).call
      end.to raise_error(ArgumentError, 'Catalog buttons are only supported for MARKETING templates')
    end

    it 'rejects Flow creation until an authoritative template contract is implemented' do
      expect do
        described_class.new(
          template_config: {
            name: 'signup_flow',
            language: 'en_US',
            category: 'marketing',
            body_text: 'Open the form.',
            buttons: [{ type: 'FLOW', text: 'Open' }]
          },
          asset_upload_service: asset_upload_service
        ).call
      end.to raise_error(ArgumentError, 'Unsupported button type: FLOW')
    end

    it 'builds validated media carousel cards with uploaded handles' do
      allow(asset_upload_service).to receive(:upload)
        .with(url: 'https://example.com/card-1.jpg', media_type: 'image')
        .and_return('4:card-1')
      allow(asset_upload_service).to receive(:upload)
        .with(url: 'https://example.com/card-2.jpg', media_type: 'image')
        .and_return('4:card-2')

      result = described_class.new(
        template_config: {
          name: 'summer_products',
          language: 'en_US',
          category: 'marketing',
          body_text: 'Choose a summer product.',
          carousel_cards: [
            {
              header_type: 'image',
              sample_media_url: 'https://example.com/card-1.jpg',
              body_text: 'Product one',
              buttons: [{ type: 'QUICK_REPLY', text: 'Choose one' }]
            },
            {
              header_type: 'image',
              sample_media_url: 'https://example.com/card-2.jpg',
              body_text: 'Product two',
              buttons: [{ type: 'QUICK_REPLY', text: 'Choose two' }]
            }
          ]
        },
        asset_upload_service: asset_upload_service
      ).call

      carousel = result[:components].second
      expect(carousel[:type]).to eq('CAROUSEL')
      expect(carousel[:cards].size).to eq(2)
      expect(carousel[:cards].first).to eq(
        components: [
          { type: 'HEADER', format: 'IMAGE', example: { header_handle: ['4:card-1'] } },
          { type: 'BODY', text: 'Product one' },
          { type: 'BUTTONS', buttons: [{ type: 'QUICK_REPLY', text: 'Choose one' }] }
        ]
      )
    end

    it 'requires every carousel card to use the same component structure' do
      allow(asset_upload_service).to receive(:upload).and_return('4:sample')

      expect do
        described_class.new(
          template_config: {
            name: 'broken_carousel',
            language: 'en_US',
            category: 'marketing',
            body_text: 'Choose a product.',
            carousel_cards: [
              { header_type: 'image', sample_media_url: 'https://example.com/1.jpg', body_text: 'One' },
              { header_type: 'image', sample_media_url: 'https://example.com/2.jpg' }
            ]
          },
          asset_upload_service: asset_upload_service
        ).call
      end.to raise_error(ArgumentError, 'All carousel cards must use the same component and button structure')
    end
  end
end
