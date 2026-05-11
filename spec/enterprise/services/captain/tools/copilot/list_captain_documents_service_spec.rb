require 'rails_helper'

RSpec.describe Captain::Tools::Copilot::ListCaptainDocumentsService do
  let(:account) { create(:account) }
  let(:user) { create(:user, :administrator, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:service) { described_class.new(assistant, user: user) }

  def create_pdf_document(name: 'Price list')
    build(:captain_document, assistant: assistant, account: account, name: name, external_link: nil, status: :available).tap do |document|
      document.pdf_file.attach(
        io: StringIO.new('%PDF-1.4 file'),
        filename: 'price-list.pdf',
        content_type: 'application/pdf'
      )
      document.save!
    end
  end

  it 'returns available source documents scoped to the assistant' do
    sendable_document = create_pdf_document
    derived_document = create(:captain_document, assistant: assistant, account: account, status: :available, metadata: {
                                'firecrawl' => { 'root_document_id' => sendable_document.id }
                              })
    create(:captain_document, account: create(:account), status: :available, name: 'Other account')

    payload = JSON.parse(service.execute(query: 'price', limit: 5))

    expect(payload['action']).to eq('list_captain_documents')
    expect(payload['documents'].size).to eq(1)
    expect(payload['documents'].first).to include(
      'document_id' => sendable_document.id,
      'name' => 'Price list',
      'source_mode' => 'pdf_upload',
      'status' => 'available',
      'content_type' => 'application/pdf',
      'sendable' => true,
      'filename' => 'price-list.pdf'
    )
    expect(payload['documents'].first['artifact_id']).to be_present
    expect(payload['documents'].first).not_to have_key('external_link')
    expect(payload['documents'].pluck('document_id')).not_to include(derived_document.id)
  end

  it 'returns URL documents as not sendable file attachments' do
    document = create(:captain_document, assistant: assistant, account: account, name: 'Guide', external_link: 'https://example.com/guide',
                                         status: :available)

    payload = JSON.parse(service.execute(sendable_only: false))

    document_payload = payload['documents'].find { |item| item['document_id'] == document.id }
    expect(document_payload).to include('sendable' => false, 'external_link' => 'https://example.com/guide')
    expect(document_payload).not_to have_key('artifact_id')
  end

  it 'can filter to sendable uploaded documents only' do
    create(:captain_document, assistant: assistant, account: account, name: 'Guide', external_link: 'https://example.com/guide', status: :available)
    sendable_document = create_pdf_document(name: 'Attachment')

    payload = JSON.parse(service.execute(sendable_only: true))

    expect(payload['documents'].pluck('document_id')).to eq([sendable_document.id])
  end
end
