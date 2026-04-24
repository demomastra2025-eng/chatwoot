require 'rails_helper'

RSpec.describe Captain::Tools::AttachmentResolver do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:resolver) { described_class.new(account: account, assistant: assistant) }

  def blob_for(account_id:)
    ActiveStorage::Blob.create_and_upload!(
      io: File.open('spec/assets/avatar.png', 'rb'),
      filename: 'avatar.png',
      content_type: 'image/png',
      metadata: { 'account_id' => account_id }
    )
  end

  it 'accepts direct blob ids scoped to the current account metadata' do
    blob = blob_for(account_id: account.id)

    expect(resolver.resolve(attachment_ids: [blob.signed_id], artifact_ids: [])).to eq([blob.signed_id])
  end

  it 'rejects direct blob ids scoped to another account' do
    blob = blob_for(account_id: create(:account).id)

    expect do
      resolver.resolve(attachment_ids: [blob.signed_id], artifact_ids: [])
    end.to raise_error(ArgumentError, 'Attachment does not belong to the current account')
  end

  it 'accepts blobs already attached to records in the current account' do
    conversation = create(:conversation, account: account)
    message = create(:message, account: account, inbox: conversation.inbox, conversation: conversation)
    attachment = message.attachments.create!(account: account, file: blob_for(account_id: nil))

    expect(resolver.resolve(attachment_ids: [attachment.file.blob.signed_id], artifact_ids: [])).to eq([attachment.file.blob.signed_id])
  end
end
