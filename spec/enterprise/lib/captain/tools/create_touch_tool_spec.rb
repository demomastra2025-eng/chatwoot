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
    payload = JSON.parse(tool.perform(tool_context, body: 'Ping client tomorrow', scheduled_at: 2.days.from_now.iso8601,
                                                    auto_cancel_on_incoming: true))

    expect(payload).to include('action' => 'create_touch')
    expect(payload['touch']).to include('body' => 'Ping client tomorrow', 'status' => 'pending', 'auto_cancel_on_incoming' => true)
  end

  it 'passes selected attachments to the reminder pipeline' do
    signed_blob_id = account_owned_blob.signed_id

    payload = JSON.parse(tool.perform(
                           tool_context,
                           body: 'Ping client with a file',
                           scheduled_at: 2.days.from_now.iso8601,
                           attachment_ids: [signed_blob_id]
                         ))

    expect(payload.dig('touch', 'attachments')).to eq([signed_blob_id])
    expect(Reminder.last.attachments).to eq([signed_blob_id])
  end
end
