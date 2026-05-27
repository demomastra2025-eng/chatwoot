require 'rails_helper'

RSpec.describe Whatsapp::LiquidTemplateProcessorService do
  let(:account) { create(:account, name: 'OneLink') }
  let(:agent) { create(:user, account: account, name: 'Agent Smith', email: 'agent@example.com') }
  let(:inbox) { create(:inbox, account: account, name: 'Support Inbox') }
  let(:contact) do
    create(
      :contact,
      account: account,
      name: 'Jane Doe',
      email: 'jane@example.com',
      custom_attributes: { 'plan' => 'Premium' }
    )
  end
  let(:campaign) { create(:campaign, account: account, inbox: inbox, sender: agent, message: 'Test message') }
  let(:service) { described_class.new(campaign: campaign, contact: contact) }

  describe '#process_template_params' do
    it 'renders contact, agent, inbox, account and custom attribute variables without mutating the original params' do
      template_params = {
        'name' => 'status_update',
        'processed_params' => {
          'header' => { 'media_name' => '{{contact.custom_attribute.plan}}.pdf' },
          'body' => {
            'contact_name' => '{{contact.name}}',
            'agent_email' => '{{agent.email}}',
            'inbox_name' => '{{inbox.name}}',
            'account_name' => '{{account.name}}'
          },
          'buttons' => [{ 'parameter' => 'ticket-{{contact.email}}' }]
        }
      }

      result = service.process_template_params(template_params)

      expect(result['processed_params']['header']['media_name']).to eq('Premium.pdf')
      expect(result['processed_params']['body']['contact_name']).to eq(ContactDrop.new(contact).name)
      expect(result['processed_params']['body']['agent_email']).to eq(agent.email)
      expect(result['processed_params']['body']['inbox_name']).to eq(inbox.name)
      expect(result['processed_params']['body']['account_name']).to eq(account.name)
      expect(result['processed_params']['buttons'][0]['parameter']).to eq("ticket-#{contact.email}")
      expect(template_params['processed_params']['body']['agent_email']).to eq('{{agent.email}}')
    end

    it 'preserves JSON validity when rendered values contain quotes or newlines' do
      contact.update!(name: "Jane \"Quoted\"\nDoe")
      template_params = {
        'name' => 'quote_update',
        'processed_params' => { 'body' => { 'name' => '{{contact.name}}' } }
      }

      result = service.process_template_params(template_params)

      expect(result['processed_params']['body']['name']).to eq(ContactDrop.new(contact).name)
    end

    it 'returns nil when any liquid variable inside a required value resolves blank' do
      contact.update!(email: nil)
      template_params = {
        'name' => 'blank_update',
        'processed_params' => { 'body' => { 'email' => 'ticket-{{contact.email}}' } }
      }

      expect(service.process_template_params(template_params)).to be_nil
    end

    it 'raises liquid rendering errors so campaign deliveries can fail instead of sending raw params' do
      template_params = {
        'name' => 'invalid_update',
        'processed_params' => { 'body' => { 'invalid' => '{{contact.name | split: }}' } }
      }

      expect { service.process_template_params(template_params) }.to raise_error(Liquid::Error)
    end

    it 'keeps strings without complete liquid expressions unchanged' do
      template_params = {
        'name' => 'invalid_update',
        'processed_params' => { 'body' => { 'invalid' => '{{contact.name missing braces' } }
      }

      result = service.process_template_params(template_params)

      expect(result['processed_params']['body']['invalid']).to eq('{{contact.name missing braces')
    end
  end
end
