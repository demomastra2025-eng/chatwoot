require 'rails_helper'

RSpec.describe Whatsapp::TemplateProcessorService do
  let(:channel) { create(:channel_whatsapp, sync_templates: false, validate_provider_config: false) }

  describe '#call' do
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

    it 'rejects authentication templates even if they exist in the local cache' do
      channel.update!(
        message_templates: [
          {
            'name' => 'auth_template',
            'language' => 'en_US',
            'status' => 'APPROVED',
            'category' => 'AUTHENTICATION',
            'components' => [{ 'type' => 'BODY', 'text' => 'Your code is {{1}}' }]
          }
        ]
      )

      template_params = {
        'name' => 'auth_template',
        'language' => 'en_US',
        'processed_params' => { 'body' => { '1' => '123456' } }
      }

      service = described_class.new(channel: channel, template_params: template_params)

      expect(service.call).to eq(['auth_template', nil, 'en_US', nil])
    end

    it 'rejects unsupported interactive template component types' do
      channel.update!(
        message_templates: [
          {
            'name' => 'carousel_template',
            'language' => 'en_US',
            'status' => 'APPROVED',
            'components' => [
              { 'type' => 'BODY', 'text' => 'Check this out' },
              { 'type' => 'CAROUSEL', 'cards' => [] }
            ]
          }
        ]
      )

      template_params = {
        'name' => 'carousel_template',
        'language' => 'en_US',
        'processed_params' => { 'body' => { '1' => 'ignored' } }
      }

      service = described_class.new(channel: channel, template_params: template_params)

      expect(service.call).to eq(['carousel_template', nil, 'en_US', nil])
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
