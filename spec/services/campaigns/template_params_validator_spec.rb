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
end
