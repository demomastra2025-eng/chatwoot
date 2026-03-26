require 'rails_helper'

RSpec.describe Captain::Tools::FirecrawlParserJob, type: :job do
  let(:assistant) { create(:captain_assistant) }

  describe '#perform' do
    let(:payload) do
      {
        markdown: 'Updated markdown',
        metadata: {
          url: 'https://example.com/docs/page-1',
          title: 'Page 1'
        }
      }
    end

    it 'creates a derived document for a source document' do
      source_document = create(
        :captain_document,
        assistant: assistant,
        external_link: 'https://example.com/docs',
        metadata: {
          'firecrawl' => {
            'mode' => 'site_import',
            'sync' => { 'status' => 'processing', 'pages_total' => 2 }
          }
        }
      )

      expect do
        described_class.perform_now(
          assistant_id: assistant.id,
          payload: payload,
          source_document_id: source_document.id
        )
      end.to change(assistant.documents, :count).by(1)

      derived_document = assistant.documents.order(:created_at).last
      expect(derived_document.metadata.dig('firecrawl', 'root_document_id')).to eq(source_document.id)
      expect(source_document.reload.pages_processed).to eq(1)
    end

    it 'skips unchanged pages during delta refresh' do
      source_document = create(
        :captain_document,
        assistant: assistant,
        external_link: 'https://example.com/docs',
        metadata: {
          'firecrawl' => {
            'mode' => 'site_import',
            'sync' => { 'refresh_mode' => 'delta', 'status' => 'processing', 'pages_total' => 1 }
          }
        }
      )

      expect do
        described_class.perform_now(
          assistant_id: assistant.id,
          payload: payload.merge(changeTracking: { changeStatus: 'same' }),
          source_document_id: source_document.id
        )
      end.not_to change(assistant.documents, :count)

      expect(source_document.reload.pages_processed).to eq(1)
      expect(source_document.metadata.dig('firecrawl', 'sync', 'same_urls')).to include('https://example.com/docs/page-1')
    end
  end
end
