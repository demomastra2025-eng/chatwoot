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

  it 'keeps derived documents workspace-owned when the source document has no assistant' do
    source_document.update!(assistant: nil, visibility: :general)

    described_class.perform_now(
      assistant_id: assistant.id,
      source_document_id: source_document.id,
      payload: {
        markdown: 'Workspace child page text',
        metadata: {
          url: 'https://example.com/docs/workspace-child',
          title: 'Workspace child page'
        }
      }
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

    described_class.perform_now(
      assistant_id: assistant.id,
      source_document_id: source_document.id,
      payload: {
        markdown: 'Workspace replacement content',
        metadata: {
          url: 'https://example.com/docs/conflict',
          title: 'Workspace conflict'
        }
      }
    )

    expect(conflicting_document.reload.assistant_id).to eq(other_assistant.id)
    expect(conflicting_document).to be_visibility_personal
    expect(conflicting_document.source_text).to eq('Original personal content')
  end
end
