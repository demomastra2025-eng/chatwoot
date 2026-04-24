require 'rails_helper'

RSpec.describe Captain::Tools::Copilot::CreateTouchService do
  let(:account) { create(:account) }
  let(:user) { create(:user, :administrator, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:conversation) { create(:conversation, account: account) }
  let(:service) { described_class.new(assistant, user: user, conversation: conversation) }
  let(:account_owned_blob) do
    ActiveStorage::Blob.create_and_upload!(
      io: File.open('spec/assets/avatar.png', 'rb'),
      filename: 'avatar.png',
      content_type: 'image/png',
      metadata: { 'account_id' => account.id }
    )
  end

  it 'returns a normalized touch payload wrapper' do
    payload = JSON.parse(service.execute(body: 'Ping client tomorrow', scheduled_at: 2.days.from_now.iso8601))

    expect(payload).to include('action' => 'create_touch')
    expect(payload.fetch('touch')).to include(
      'body' => 'Ping client tomorrow',
      'status' => 'pending'
    )
  end

  it 'passes selected attachments to the reminder pipeline' do
    signed_blob_id = account_owned_blob.signed_id

    payload = JSON.parse(service.execute(
                           body: 'Ping client with a file',
                           scheduled_at: 2.days.from_now.iso8601,
                           attachment_ids: [signed_blob_id]
                         ))

    expect(payload.dig('touch', 'attachments')).to eq([signed_blob_id])
    expect(Reminder.last.attachments).to eq([signed_blob_id])
  end

  it 'creates a channel_template touch and returns template metadata in the payload' do
    whatsapp_channel = create(:channel_whatsapp, account: account, sync_templates: false, validate_provider_config: false)
    whatsapp_inbox = whatsapp_channel.inbox
    contact = create(:contact, account: account)
    contact_inbox = create(:contact_inbox, contact: contact, inbox: whatsapp_inbox)
    whatsapp_conversation = create(:conversation, account: account, inbox: whatsapp_inbox, contact: contact, contact_inbox: contact_inbox)
    whatsapp_service = described_class.new(assistant, user: user, conversation: whatsapp_conversation)
    template_params = {
      name: 'sample_shipping_confirmation',
      language: 'en_US',
      namespace: '23423423_2342423_324234234_2343224',
      processed_params: { '1' => '2' }
    }

    payload = JSON.parse(whatsapp_service.execute(
                           content_kind: 'channel_template',
                           template_params: template_params,
                           scheduled_at: 2.days.from_now.iso8601
                         ))

    expect(payload['action']).to eq('create_touch')
    expect(payload.dig('touch', 'content_kind')).to eq('channel_template')
    expect(Reminder.last.template_params).to include('name' => 'sample_shipping_confirmation')
    expect(Reminder.last.metadata['delivery_policy']).to include('delivery_mode' => 'channel_template')
  end
end
