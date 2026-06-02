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

  it 'keeps derived documents workspace-owned when the source document has no assistant' do
    source_document.update!(assistant: nil, visibility: :general)
    crawler = instance_double(
      Captain::Tools::SimplePageCrawlService,
      page_title: 'Workspace child page',
      body_text_content: 'Workspace child page text'
    )
    allow(Captain::Tools::SimplePageCrawlService)
      .to receive(:new)
      .with('https://example.com/docs/workspace-child')
      .and_return(crawler)

    described_class.perform_now(
      assistant_id: assistant.id,
      source_document_id: source_document.id,
      page_link: 'https://example.com/docs/workspace-child'
    )

    derived_document = assistant.account.captain_documents.find_by!(external_link: 'https://example.com/docs/workspace-child')
    expect(derived_document.assistant_id).to be_nil
    expect(derived_document).to be_visibility_general
  end

  it 'does not overwrite an existing derived document from another assistant context' do
    other_assistant = create(:captain_assistant, account: assistant.account)
    source_document.update!(assistant: nil, visibility: :general)
    conflicting_document = create(
      :captain_document,
      account: assistant.account,
      assistant: other_assistant,
      visibility: :personal,
      external_link: 'https://example.com/docs/conflict',
      source_text: 'Original personal content'
    )
    crawler = instance_double(
      Captain::Tools::SimplePageCrawlService,
      page_title: 'Workspace conflict',
      body_text_content: 'Workspace replacement content'
    )
    allow(Captain::Tools::SimplePageCrawlService)
      .to receive(:new)
      .with('https://example.com/docs/conflict')
      .and_return(crawler)

    described_class.perform_now(
      assistant_id: assistant.id,
      source_document_id: source_document.id,
      page_link: 'https://example.com/docs/conflict'
    )

    expect(conflicting_document.reload.assistant_id).to eq(other_assistant.id)
    expect(conflicting_document).to be_visibility_personal
    expect(conflicting_document.source_text).to eq('Original personal content')
  end

  it 'does not overwrite another assistant personal document without a source document' do
    other_assistant = create(:captain_assistant, account: assistant.account)
    conflicting_document = create(
      :captain_document,
      account: assistant.account,
      assistant: other_assistant,
      visibility: :personal,
      external_link: 'https://example.com/docs/no-source-conflict',
      source_text: 'Original personal content'
    )
    crawler = instance_double(
      Captain::Tools::SimplePageCrawlService,
      page_title: 'No source conflict',
      body_text_content: 'Replacement content'
    )
    allow(Captain::Tools::SimplePageCrawlService)
      .to receive(:new)
      .with('https://example.com/docs/no-source-conflict')
      .and_return(crawler)

    described_class.perform_now(
      assistant_id: assistant.id,
      page_link: 'https://example.com/docs/no-source-conflict'
    )

    expect(conflicting_document.reload.assistant_id).to eq(other_assistant.id)
    expect(conflicting_document).to be_visibility_personal
    expect(conflicting_document.source_text).to eq('Original personal content')
  end
end
