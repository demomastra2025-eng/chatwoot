require 'rails_helper'

RSpec.describe Captain::Tools::FirecrawlParserJob, type: :job do
  let(:assistant) { create(:captain_assistant) }
  let(:source_document) do
    create(
      :captain_document,
      assistant: assistant,
      account: assistant.account,
      external_link: 'https://example.com/docs',
      faq_generation_enabled: false,
      metadata: {
        'firecrawl' => {
          'mode' => 'site_import',
          'sync' => {}
        }
      }
    )
  end

  it 'propagates disabled FAQ generation to derived Firecrawl documents' do
    described_class.perform_now(
      assistant_id: assistant.id,
      source_document_id: source_document.id,
      payload: {
        markdown: 'Full child page text',
        metadata: {
          url: 'https://example.com/docs/child',
          title: 'Child page'
        }
      }
    )

    derived_document = assistant.documents.find_by!(external_link: 'https://example.com/docs/child')
    expect(derived_document.faq_generation_enabled).to be false
    expect(derived_document.source_text).to eq('Full child page text')
    expect(derived_document.content).to eq('Full child page text')
  end
end
