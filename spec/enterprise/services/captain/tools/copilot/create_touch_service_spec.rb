require 'rails_helper'

RSpec.describe Captain::Tools::Copilot::CreateTouchService do
  let(:account) { create(:account) }
  let(:user) { create(:user, :administrator, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:conversation) { create(:conversation, account: account) }
  let(:copilot_thread) { create(:captain_copilot_thread, account: account, user: user, assistant: assistant) }
  let(:service) { described_class.new(assistant, user: user, conversation: conversation, copilot_thread: copilot_thread) }
  let(:account_owned_blob) do
    ActiveStorage::Blob.create_and_upload!(
      io: File.open('spec/assets/avatar.png', 'rb'),
      filename: 'avatar.png',
      content_type: 'image/png',
      metadata: { 'account_id' => account.id }
    )
  end

  it 'returns a normalized touch payload wrapper' do
    payload = JSON.parse(execute_confirmed(body: 'Ping client tomorrow', scheduled_at: 2.days.from_now.iso8601, auto_cancel_on_incoming: true))

    expect(payload).to include(
      'action' => 'create_touch',
      'touch_id' => Reminder.last.id,
      'status' => 'pending',
      'content_kind' => 'free_text',
      'timing_mode' => 'absolute',
      'auto_cancel_on_incoming' => true
    )
    expect(payload.fetch('touch')).to include(
      'body' => 'Ping client tomorrow',
      'status' => 'pending',
      'auto_cancel_on_incoming' => true
    )
  end

  it 'passes selected attachments to the reminder pipeline' do
    signed_blob_id = account_owned_blob.signed_id

    payload = JSON.parse(execute_confirmed(
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
    whatsapp_service = described_class.new(assistant, user: user, conversation: whatsapp_conversation, copilot_thread: copilot_thread)
    template_params = {
      name: 'sample_shipping_confirmation',
      language: 'en_US',
      namespace: '23423423_2342423_324234234_2343224',
      processed_params: { '1' => '2' }
    }

    payload = JSON.parse(execute_confirmed(
                           whatsapp_service,
                           content_kind: 'channel_template',
                           template_params: template_params,
                           scheduled_at: 2.days.from_now.iso8601
                         ))

    expect(payload['action']).to eq('create_touch')
    expect(payload).to include(
      'content_kind' => 'channel_template',
      'template_name' => 'sample_shipping_confirmation',
      'template_language' => 'en_US'
    )
    expect(payload.dig('touch', 'content_kind')).to eq('channel_template')
    expect(Reminder.last.template_params).to include('name' => 'sample_shipping_confirmation')
    expect(Reminder.last.metadata['delivery_policy']).to include('delivery_mode' => 'channel_template')
  end

  def execute_confirmed(target_service = service, **arguments)
    first_result = target_service.execute(**arguments)
    first_payload = JSON.parse(first_result)
    expect(first_payload.dig('data', 'confirmation_required')).to be(true)

    confirmation_token = copilot_thread.copilot_messages.assistant_thinking.last.message.dig('confirmation_gate', 'confirmation_token')

    create(
      :captain_copilot_message,
      account: account,
      copilot_thread: copilot_thread,
      message_type: 'user',
      message: { 'content' => "Подтверждаю #{confirmation_token}" }
    )

    target_service.execute(**arguments)
  end
end
