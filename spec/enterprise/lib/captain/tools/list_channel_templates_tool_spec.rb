require 'rails_helper'

RSpec.describe Captain::Tools::ListChannelTemplatesTool, type: :model do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:tool) { described_class.new(assistant) }

  it 'returns approved templates for the current WhatsApp conversation' do
    whatsapp_channel = create(:channel_whatsapp, account: account, sync_templates: false, validate_provider_config: false)
    inbox = whatsapp_channel.inbox
    contact = create(:contact, account: account)
    contact_inbox = create(:contact_inbox, contact: contact, inbox: inbox)
    conversation = create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox)
    tool_context = Struct.new(:state).new({ conversation: { id: conversation.id }, contact: { id: contact.id } })

    payload = JSON.parse(tool.perform(tool_context, name: 'sample_shipping_confirmation', language: 'en_US'))

    expect(payload['action']).to eq('list_channel_templates')
    expect(payload).to include(
      'inbox_id' => inbox.id,
      'channel_type' => 'Channel::Whatsapp',
      'supports_channel_templates' => true,
      'requires_template_for_outside_window' => true,
      'total_count' => 1,
      'filters' => { 'name' => 'sample_shipping_confirmation', 'language' => 'en_US', 'status' => 'approved' }
    )
    expect(payload.dig('templates', 0)).to include(
      'name' => 'sample_shipping_confirmation',
      'language' => 'en_US',
      'supported' => true
    )
  end
end
