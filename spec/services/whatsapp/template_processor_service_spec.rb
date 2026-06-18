require 'rails_helper'

RSpec.describe Whatsapp::TemplateProcessorService do
  let(:channel) { create(:channel_whatsapp, provider: 'whatsapp_cloud', sync_templates: false, validate_provider_config: false) }

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

      expect(processed_params).to eq([
        {
          type: 'body',
          parameters: [{ type: 'text', parameter_name: 'ticket_id', text: '123' }]
        }
      ])
    end

    it 'builds safe runtime parameters for WhatsApp Flow template buttons' do
      flow = create(:whatsapp_flow, account: channel.account, inbox: channel.inbox,
                                    provider_flow_id: 'flow-123', name: 'lead_qualification')
      contact_inbox = create(:contact_inbox, inbox: channel.inbox, source_id: '123456789')
      conversation = create(:conversation, contact_inbox: contact_inbox, inbox: channel.inbox)
      message = create(:message, :bot_message, account: channel.account, conversation: conversation, message_type: :outgoing,
                                 content: 'Please complete the lead form',
                                 additional_attributes: {
                                   'template_params' => {
                                     'name' => 'lead_flow_template',
                                     'language' => 'en_US',
                                     'category' => 'MARKETING',
                                     'processed_params' => {
                                       'buttons' => [
                                         {
                                           'type' => 'flow',
                                           'whatsapp_flow_id' => flow.id,
                                           'flow_action_data' => { 'lead_id' => 'deal-1' }
                                         }
                                       ]
                                     }
                                   }
                                 })

      channel.update!(
        message_templates: [
          {
            'name' => 'lead_flow_template',
            'language' => 'en_US',
            'status' => 'APPROVED',
            'category' => 'MARKETING',
            'components' => [
              { 'type' => 'BODY', 'text' => 'Please fill the lead form' },
              { 'type' => 'BUTTONS', 'buttons' => [{ 'type' => 'FLOW', 'text' => 'Open form' }] }
            ]
          }
        ]
      )

      template_params = {
        'name' => 'lead_flow_template',
        'language' => 'en_US',
        'processed_params' => message.additional_attributes.dig('template_params', 'processed_params')
      }

      _, _, _, processed_params = described_class.new(channel: channel, template_params: template_params, message: message).call
      flow_session = Whatsapp::FlowSession.find_by!(flow: flow, message: message)

      expect(processed_params).to eq([
        {
          type: 'button',
          sub_type: 'flow',
          index: '0',
          parameters: [
            {
              type: 'action',
              action: {
                flow_token: flow_session.token,
                flow_action_data: { 'lead_id' => 'deal-1' }
              }
            }
          ]
        }
      ])
      expect(message.reload.additional_attributes.dig('template_params', 'processed_params', 'buttons', 0)).to include(
        'flow_session_id' => flow_session.id
      )
      expect(message.additional_attributes.to_json).not_to include(flow_session.token)
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
  end
end
