require 'rails_helper'

RSpec.describe Captain::Tools::SimplePageCrawlParserJob, type: :job do
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

  it 'propagates disabled FAQ generation to derived simple-crawl documents' do
    crawler = instance_double(
      Captain::Tools::SimplePageCrawlService,
      page_title: 'Child page',
      body_text_content: 'Simple child page text'
    )
    allow(Captain::Tools::SimplePageCrawlService)
      .to receive(:new)
      .with('https://example.com/docs/child')
      .and_return(crawler)

    described_class.perform_now(
      assistant_id: assistant.id,
      source_document_id: source_document.id,
      page_link: 'https://example.com/docs/child'
    )

    derived_document = assistant.documents.find_by!(external_link: 'https://example.com/docs/child')
    expect(derived_document.faq_generation_enabled).to be false
    expect(derived_document.source_text).to eq('Simple child page text')
    expect(derived_document.content).to eq('Simple child page text')
  end
end
