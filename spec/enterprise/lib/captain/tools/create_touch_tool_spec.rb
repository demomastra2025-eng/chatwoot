require 'rails_helper'

RSpec.describe Captain::Tools::CreateTouchTool, type: :model do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:tool) { described_class.new(assistant) }
  let(:contact) { create(:contact, account: account) }
  let(:conversation) { create(:conversation, account: account, contact: contact) }
  let(:tool_context) { Struct.new(:state).new({ conversation: { id: conversation.id }, contact: { id: contact.id } }) }
  let(:account_owned_blob) do
    ActiveStorage::Blob.create_and_upload!(
      io: File.open('spec/assets/avatar.png', 'rb'),
      filename: 'avatar.png',
      content_type: 'image/png',
      metadata: { 'account_id' => account.id }
    )
  end

  it 'returns normalized create_touch payload' do
    create(:message, account: account, conversation: conversation, inbox: conversation.inbox, message_type: :incoming, created_at: 10.minutes.ago)

    payload = JSON.parse(tool.perform(tool_context, body: 'Ping client tomorrow', relative_offset_minutes: 15,
                                                    auto_cancel_on_incoming: true))

    expect(payload).to include(
      'action' => 'create_touch',
      'touch_id' => Reminder.last.id,
      'status' => 'pending',
      'content_kind' => 'free_text',
      'timing_mode' => 'relative',
      'auto_cancel_on_incoming' => true
    )
    expect(payload['touch']).to include(
      'body' => 'Ping client tomorrow',
      'status' => 'pending',
      'auto_cancel_on_incoming' => true,
      'relative_anchor' => 'conversation.last_incoming_message_at',
      'relative_offset_seconds' => 15.minutes.to_i
    )
  end

  it 'returns template metadata at the top level for channel_template touches' do
    whatsapp_channel = create(:channel_whatsapp, account: account, sync_templates: false, validate_provider_config: false)
    whatsapp_inbox = whatsapp_channel.inbox
    whatsapp_contact_inbox = create(:contact_inbox, contact: contact, inbox: whatsapp_inbox)
    whatsapp_conversation = create(:conversation, account: account, inbox: whatsapp_inbox, contact: contact,
                                                  contact_inbox: whatsapp_contact_inbox)
    whatsapp_context = Struct.new(:state).new({ conversation: { id: whatsapp_conversation.id }, contact: { id: contact.id } })
    template_params = {
      name: 'sample_shipping_confirmation',
      language: 'en_US',
      namespace: '23423423_2342423_324234234_2343224',
      processed_params: { '1' => '2' }
    }

    payload = JSON.parse(tool.perform(
                           whatsapp_context,
                           content_kind: 'channel_template',
                           template_params: template_params,
                           relative_anchor: 'touch.created_at',
                           relative_offset_minutes: 2.days.in_minutes
                         ))

    expect(payload).to include(
      'action' => 'create_touch',
      'content_kind' => 'channel_template',
      'template_name' => 'sample_shipping_confirmation',
      'template_language' => 'en_US'
    )
    expect(payload.dig('touch', 'template_params')).to include('name' => 'sample_shipping_confirmation')
  end

  it 'passes selected attachments to the reminder pipeline' do
    signed_blob_id = account_owned_blob.signed_id

    payload = JSON.parse(tool.perform(
                           tool_context,
                           body: 'Ping client with a file',
                           relative_anchor: 'touch.created_at',
                           relative_offset_minutes: 2.days.in_minutes,
                           attachment_ids: [signed_blob_id]
                         ))

    expect(payload.dig('touch', 'attachments')).to eq([signed_blob_id])
    expect(Reminder.last.attachments).to eq([signed_blob_id])
  end
end
