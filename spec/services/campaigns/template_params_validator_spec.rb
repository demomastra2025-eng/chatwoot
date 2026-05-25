require 'rails_helper'

RSpec.describe Campaigns::TemplateParamsValidator do
  let(:account) { create(:account) }
  let(:whatsapp_inbox) { create(:channel_whatsapp, account: account, sync_templates: false, validate_provider_config: false).inbox }

  before do
    whatsapp_inbox.channel.update!(
      message_templates: [
        {
          'name' => 'ticket_status_updated',
          'status' => 'approved',
          'category' => 'MARKETING',
          'language' => 'en',
          'components' => [{ 'type' => 'BODY', 'text' => 'Hi {{name}}, ticket {{ticket_id}} is updated' }]
        },
        {
          'name' => 'ticket_action_buttons',
          'status' => 'approved',
          'category' => 'MARKETING',
          'language' => 'en',
          'components' => [
            { 'type' => 'BODY', 'text' => 'Ticket action available' },
            {
              'type' => 'BUTTONS',
              'buttons' => [
                { 'type' => 'QUICK_REPLY', 'text' => 'Later' },
                { 'type' => 'URL', 'url' => 'https://example.com/tickets/{{1}}' },
                { 'type' => 'COPY_CODE' }
              ]
            }
          ]
        }
      ]
    )
  end

  it 'accepts approved supported templates with required params' do
    expect do
      described_class.validate!(
        inbox: whatsapp_inbox,
        template_params: {
          name: 'ticket_status_updated',
          language: 'en',
          processed_params: { body: { name: 'John', ticket_id: '123' } }
        }
      )
    end.not_to raise_error
  end

  it 'rejects unknown or unapproved templates' do
    expect do
      described_class.validate!(
        inbox: whatsapp_inbox,
        template_params: {
          name: 'missing_template',
          language: 'en',
          processed_params: { body: { name: 'John' } }
        }
      )
    end.to raise_error(ArgumentError, /Approved channel template was not found/)
  end

  it 'rejects approved templates when required params are missing' do
    expect do
      described_class.validate!(
        inbox: whatsapp_inbox,
        template_params: {
          name: 'ticket_status_updated',
          language: 'en',
          processed_params: { body: { name: 'John' } }
        }
      )
    end.to raise_error(ArgumentError, /body.ticket_id/)
  end

  it 'requires each dynamic button parameter by button position' do
    expect do
      described_class.validate!(
        inbox: whatsapp_inbox,
        template_params: {
          name: 'ticket_action_buttons',
          language: 'en',
          processed_params: { buttons: [nil, { parameter: 'TRACK-123' }] }
        }
      )
    end.to raise_error(ArgumentError, /buttons.2/)
  end

  it 'accepts approved templates with all dynamic button parameters' do
    expect do
      described_class.validate!(
        inbox: whatsapp_inbox,
        template_params: {
          name: 'ticket_action_buttons',
          language: 'en',
          processed_params: { buttons: [nil, { parameter: 'TRACK-123' }, { parameter: 'SAVE20' }] }
        }
      )
    end.not_to raise_error
  end
end
