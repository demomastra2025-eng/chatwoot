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
          'job_id' => 'job-123',
          'sync' => {}
        }
      }
    )
  end

  it 'propagates disabled FAQ generation to derived Firecrawl documents' do
    described_class.perform_now(
      assistant_id: assistant.id,
      source_document_id: source_document.id,
      job_id: 'job-123',
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
    expect(source_document.reload.firecrawl_sync['processed_urls']).to include('https://example.com/docs/child')
  end

  it 'keeps derived documents workspace-owned when the source document has no assistant' do
    source_document.update!(assistant: nil, visibility: :general)

    described_class.perform_now(
      assistant_id: assistant.id,
      source_document_id: source_document.id,
      job_id: 'job-123',
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
      job_id: 'job-123',
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

    described_class.perform_now(
      assistant_id: assistant.id,
      payload: {
        markdown: 'Replacement content',
        metadata: {
          url: 'https://example.com/docs/no-source-conflict',
          title: 'No source conflict'
        }
      }
    )

    expect(conflicting_document.reload.assistant_id).to eq(other_assistant.id)
    expect(conflicting_document).to be_visibility_personal
    expect(conflicting_document.source_text).to eq('Original personal content')
  end

  it 'rejects an off-domain page returned by Firecrawl' do
    described_class.perform_now(
      assistant_id: assistant.id,
      source_document_id: source_document.id,
      job_id: 'job-123',
      payload: {
        markdown: 'Unexpected external content',
        metadata: { url: 'https://evil.example.org/page', title: 'External page' }
      }
    )

    expect(assistant.account.captain_documents.find_by(external_link: 'https://evil.example.org/page')).to be_nil
    expect(source_document.reload.failed_urls).to eq(['https://evil.example.org/page'])
  end

  it 'accepts the Firecrawl sourceURL metadata variant' do
    described_class.perform_now(
      assistant_id: assistant.id,
      source_document_id: source_document.id,
      job_id: 'job-123',
      payload: {
        markdown: 'Source URL page text',
        metadata: { sourceURL: 'https://example.com/docs/source-url', title: 'Source URL page' }
      }
    )

    document = assistant.documents.find_by!(external_link: 'https://example.com/docs/source-url')
    expect(document.source_text).to eq('Source URL page text')
  end

  it 'ignores a parser job from a stale import run' do
    active_run_id = SecureRandom.uuid
    source_document.update!(
      metadata: source_document.metadata.deep_merge(
        'firecrawl' => { 'sync' => { 'import_run_id' => active_run_id } }
      )
    )

    described_class.perform_now(
      assistant_id: assistant.id,
      source_document_id: source_document.id,
      job_id: 'job-123',
      import_run_id: SecureRandom.uuid,
      payload: {
        markdown: 'Stale page text',
        metadata: { url: 'https://example.com/docs/stale', title: 'Stale page' }
      }
    )

    expect(assistant.documents.find_by(external_link: 'https://example.com/docs/stale')).to be_nil
    expect(source_document.reload.current_import_run_id).to eq(active_run_id)
  end

  it 'ignores a source-bound parser job before the authoritative provider job id is stored' do
    import_run_id = SecureRandom.uuid
    source_document.update!(
      metadata: {
        'firecrawl' => {
          'mode' => 'site_import',
          'sync' => { 'import_run_id' => import_run_id, 'status' => 'processing' }
        }
      }
    )

    described_class.perform_now(
      assistant_id: assistant.id,
      source_document_id: source_document.id,
      import_run_id: import_run_id,
      job_id: 'unbound-job',
      payload: {
        markdown: 'Unbound page text',
        metadata: { url: 'https://example.com/docs/unbound', title: 'Unbound page' }
      }
    )

    expect(assistant.documents.find_by(external_link: 'https://example.com/docs/unbound')).to be_nil
    expect(source_document.reload.firecrawl_sync['processed_urls']).to be_blank
  end

  it 'ignores a parser job with a mismatched provider job id' do
    import_run_id = SecureRandom.uuid
    source_document.update!(
      metadata: source_document.metadata.deep_merge(
        'firecrawl' => {
          'job_id' => 'expected-job',
          'sync' => { 'import_run_id' => import_run_id, 'status' => 'processing' }
        }
      )
    )

    described_class.perform_now(
      assistant_id: assistant.id,
      source_document_id: source_document.id,
      import_run_id: import_run_id,
      job_id: 'wrong-job',
      payload: {
        markdown: 'Wrong job page text',
        metadata: { url: 'https://example.com/docs/wrong-job', title: 'Wrong job page' }
      }
    )

    expect(assistant.documents.find_by(external_link: 'https://example.com/docs/wrong-job')).to be_nil
    expect(source_document.reload.firecrawl_sync['processed_urls']).to be_blank
  end
end
