require 'rails_helper'

RSpec.describe Captain::FollowUpDeliveryResolver do
  let(:account) { create(:account, locale: 'en') }
  let(:contact) { create(:contact, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }

  it 'allows free text on channels without a bounded reply window' do
    inbox = create(:inbox, account: account)
    conversation = create(:conversation, account: account, inbox: inbox, contact: contact)

    result = described_class.new(conversation: conversation, assistant: assistant, step: {}).call

    expect(result).to be_allowed
    expect(result.mode).to eq('free_text')
  end

  it 'blocks WhatsApp outside the window when the resolved language has no configured template' do
    inbox = create(:channel_whatsapp, account: account, sync_templates: false, validate_provider_config: false).inbox
    conversation = create(
      :conversation,
      account: account,
      inbox: inbox,
      contact: contact,
      additional_attributes: { 'conversation_language' => 'en' }
    )
    create(
      :message,
      account: account,
      inbox: inbox,
      conversation: conversation,
      message_type: :incoming,
      created_at: 25.hours.ago
    )

    result = described_class.new(conversation: conversation, assistant: assistant, step: {}).call

    expect(result).not_to be_allowed
    expect(result.reason).to eq('template_language_missing:en')
  end

  it 'selects and validates the configured approved WhatsApp template outside the window' do
    inbox = create(:channel_whatsapp, account: account, sync_templates: false, validate_provider_config: false).inbox
    conversation = create(
      :conversation,
      account: account,
      inbox: inbox,
      contact: contact,
      additional_attributes: { 'conversation_language' => 'en' }
    )
    create(
      :message,
      account: account,
      inbox: inbox,
      conversation: conversation,
      message_type: :incoming,
      created_at: 25.hours.ago
    )
    template_params = {
      'name' => 'sample_shipping_confirmation',
      'language' => 'en_US',
      'namespace' => '23423423_2342423_324234234_2343224',
      'processed_params' => { 'body' => { '1' => '2' } }
    }

    result = described_class.new(
      conversation: conversation,
      assistant: assistant,
      step: {
        'template_variants_by_inbox' => {
          inbox.id.to_s => { 'en' => template_params }
        }
      }
    ).call

    expect(result).to be_allowed
    expect(result).to be_template
    expect(result.template_params).to eq(template_params)
    expect(result.content).to include('Your package has been shipped')
  end
end
