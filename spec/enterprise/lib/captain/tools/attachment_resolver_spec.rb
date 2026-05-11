require 'rails_helper'

RSpec.describe Captain::Tools::AttachmentResolver do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:resolver) { described_class.new(account: account, assistant: assistant) }

  def create_pdf_document(status: :available)
    build(:captain_document, assistant: assistant, account: account, status: status, external_link: nil).tap do |document|
      document.pdf_file.attach(
        io: StringIO.new('%PDF-1.4 file'),
        filename: 'manual.pdf',
        content_type: 'application/pdf'
      )
      document.save!
    end
  end

  def document_artifact_id(document, account_id: account.id, assistant_id: assistant.id)
    document.reload

    Captain::Tools::DocumentArtifactToken.encode(
      account_id: account_id,
      assistant_id: assistant_id,
      document_id: document.id,
      blob_id: document.sendable_file_blob_id,
      status: document.status,
      document_fingerprint: document.artifact_fingerprint
    )
  end

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

  it 'resolves Captain document artifact IDs to scoped uploaded document files' do
    document = create_pdf_document
    artifact_id = document_artifact_id(document)

    expect(resolver.resolve(attachment_ids: [], artifact_ids: [artifact_id])).to eq([document.pdf_file.blob.signed_id])
  end

  it 'rejects document artifact IDs issued for another account' do
    document = create_pdf_document
    artifact_id = document_artifact_id(document, account_id: create(:account).id)

    expect do
      resolver.resolve(attachment_ids: [], artifact_ids: [artifact_id])
    end.to raise_error(ArgumentError, 'Document artifact belongs to another account')
  end

  it 'rejects document artifact IDs issued for another assistant' do
    document = create_pdf_document
    other_assistant = create(:captain_assistant, account: account)
    artifact_id = document_artifact_id(document, assistant_id: other_assistant.id)

    expect do
      resolver.resolve(attachment_ids: [], artifact_ids: [artifact_id])
    end.to raise_error(ArgumentError, 'Document artifact belongs to another assistant')
  end

  it 'rejects document artifact IDs for unavailable documents' do
    document = create_pdf_document(status: :failed)
    artifact_id = document_artifact_id(document)

    expect do
      resolver.resolve(attachment_ids: [], artifact_ids: [artifact_id])
    end.to raise_error(ArgumentError, 'Document is not available to send')
  end

  it 'rejects stale document artifact IDs after the attached file changes' do
    document = create_pdf_document
    artifact_id = document_artifact_id(document)
    document.pdf_file.attach(
      io: StringIO.new('%PDF-1.4 new file'),
      filename: 'updated-manual.pdf',
      content_type: 'application/pdf'
    )
    document.save!

    expect do
      resolver.resolve(attachment_ids: [], artifact_ids: [artifact_id])
    end.to raise_error(ArgumentError, 'Document artifact file changed')
  end

  it 'keeps existing HTTP artifact IDs on the HTTP materializer path' do
    blob = blob_for(account_id: account.id)
    artifact_id = Captain::Tools::HttpArtifactToken.encode(
      account_id: account.id,
      assistant_id: assistant.id,
      url: 'https://example.com/file.pdf'
    )
    materializer = instance_double(Captain::Tools::HttpArtifactMaterializer, materialize!: blob.signed_id)
    allow(Captain::Tools::HttpArtifactMaterializer).to receive(:new).and_return(materializer)

    expect(resolver.resolve(attachment_ids: [], artifact_ids: [artifact_id])).to eq([blob.signed_id])
    expect(materializer).to have_received(:materialize!).with(artifact_id)
  end
end
