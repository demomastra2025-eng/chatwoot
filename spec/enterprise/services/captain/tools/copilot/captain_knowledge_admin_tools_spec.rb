# frozen_string_literal: true

# rubocop:disable RSpec/DescribeClass
require 'rails_helper'

RSpec.describe 'Captain knowledge admin copilot tools' do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account, name: 'Main Bot') }
  let(:admin) { create(:user, :administrator, account: account) }
  let(:document) do
    create(
      :captain_document,
      account: account,
      assistant: assistant,
      name: 'Billing Guide',
      external_link: 'https://docs.example.test/billing',
      status: :available,
      metadata: {
        'firecrawl' => {
          'mode' => 'legacy_url',
          'sync' => { 'status' => 'completed', 'failed_urls' => ['https://docs.example.test/fail'] }
        }
      }
    )
  end

  before do
    confirmation_gate = instance_double(Captain::Copilot::ToolConfirmationGate, call: nil)
    allow(Captain::Copilot::ToolConfirmationGate).to receive(:new).and_return(confirmation_gate)
    allow(Captain::Documents::CrawlJob).to receive(:perform_later)
  end

  describe Captain::Tools::Copilot::ListCaptainKnowledgeDocumentsService do
    let(:service) { described_class.new(assistant, user: admin) }

    it 'lists source documents scoped to the current account' do
      document
      create(
        :captain_document,
        account: account,
        assistant: assistant,
        name: 'Child',
        metadata: { 'firecrawl' => { 'root_document_id' => document.id } }
      )
      create(:captain_document, account: create(:account), name: 'Other Account')

      payload = JSON.parse(service.execute(query: 'Billing'))

      expect(payload['action']).to eq('list_captain_knowledge_documents')
      expect(payload['documents'].pluck('name')).to eq(['Billing Guide'])
      expect(payload['documents'].first).to include('id' => document.id, 'assistant_id' => assistant.id, 'status' => 'available')
    end

    it 'rejects direct non-admin execution as defense in depth' do
      agent = create(:user, account: account)

      result = described_class.new(assistant, user: agent).execute

      expect(result).to include('Account administrator permission is required')
    end
  end

  describe Captain::Tools::Copilot::GetCaptainKnowledgeDocumentService do
    let(:service) { described_class.new(assistant, user: admin) }

    it 'returns one redacted document without signed artifact IDs' do
      payload = JSON.parse(service.execute(document_id: document.id))
      serialized_payload = JSON.generate(payload)

      expect(payload['action']).to eq('get_captain_knowledge_document')
      expect(payload['document']).to include('id' => document.id, 'external_link' => '[FILTERED]', 'display_url' => '[FILTERED]')
      expect(serialized_payload).not_to include('docs.example.test')
      expect(serialized_payload).not_to include('secret')
      expect(serialized_payload).not_to include('artifact_id')
    end

    it 'rejects cross-account documents' do
      other_document = create(:captain_document, account: create(:account))

      result = service.execute(document_id: other_document.id)

      expect(result).to start_with('ERROR: ActiveRecord::RecordNotFound')
    end
  end

  describe Captain::Tools::Copilot::CreateCaptainKnowledgeDocumentService do
    let(:service) { described_class.new(assistant, user: admin) }

    it 'creates a remote document under the selected assistant with redacted output' do
      payload = JSON.parse(
        service.execute(
          assistant_id: assistant.id,
          name: 'Pricing Guide',
          external_link: 'https://docs.example.test/pricing',
          source_mode: 'legacy_url',
          visibility: 'personal'
        )
      )

      created_document = account.captain_documents.find(payload['document']['id'])
      expect(payload['action']).to eq('create_captain_knowledge_document')
      expect(payload['document']['external_link']).to eq('[FILTERED]')
      expect(created_document).to have_attributes(name: 'Pricing Guide', assistant_id: assistant.id, visibility: 'personal')
    end

    it 'does not mutate until the backend confirmation gate permits execution' do
      allow(Captain::Copilot::ToolConfirmationGate).to receive(:new).and_call_original

      payload = JSON.parse(
        service.execute(
          assistant_id: assistant.id,
          name: 'Needs Approval',
          external_link: 'https://docs.example.test/pending'
        )
      )

      expect(payload['message']).to include('Operator confirmation is required')
      expect(account.captain_documents.where(name: 'Needs Approval')).not_to exist
    end
  end

  describe Captain::Tools::Copilot::UpdateCaptainKnowledgeDocumentService do
    let(:service) { described_class.new(assistant, user: admin) }

    it 'updates document metadata and can move it to another assistant' do
      other_assistant = create(:captain_assistant, account: account, name: 'Knowledge Bot')

      payload = JSON.parse(
        service.execute(
          document_id: document.id,
          assistant_id: other_assistant.id,
          name: 'Updated Guide',
          visibility: 'personal',
          faq_generation_enabled: false
        )
      )

      expect(payload['action']).to eq('update_captain_knowledge_document')
      expect(payload['previous_document']).to include('id' => document.id, 'external_link' => '[FILTERED]')
      expect(payload['updated_fields']).to contain_exactly('assistant', 'name', 'visibility', 'faq_generation_enabled')
      expect(document.reload).to have_attributes(
        assistant_id: other_assistant.id,
        name: 'Updated Guide',
        visibility: 'personal',
        faq_generation_enabled: false
      )
    end

    it 'reconciles generated knowledge entries when moving a document or changing visibility' do
      entry = create(:captain_assistant_response, account: account, assistant: assistant, documentable: document, visibility: :general)
      other_assistant = create(:captain_assistant, account: account, name: 'New Owner')

      service.execute(document_id: document.id, assistant_id: other_assistant.id, visibility: 'personal')

      expect(entry.reload.assistant_id).to eq(other_assistant.id)
      expect(entry.visibility).to eq('personal')
    end
  end

  describe Captain::Tools::Copilot::ResyncCaptainKnowledgeDocumentService do
    let(:service) { described_class.new(assistant, user: admin) }

    it 'queues a safe resync for source documents' do
      payload = JSON.parse(service.execute(document_id: document.id, refresh_mode: 'full'))

      expect(payload['action']).to eq('resync_captain_knowledge_document')
      expect(payload['refresh_mode']).to eq('full')
      expect(document.reload).to be_in_progress
      expect(Captain::Documents::CrawlJob).to have_received(:perform_later).with(document)
    end
  end

  describe Captain::Tools::Copilot::DeleteCaptainKnowledgeDocumentService do
    let(:service) { described_class.new(assistant, user: admin) }

    it 'deletes a source document with redacted rollback payload' do
      payload = JSON.parse(service.execute(document_id: document.id))

      expect(payload['action']).to eq('delete_captain_knowledge_document')
      expect(payload['deleted_document']).to include('id' => document.id, 'external_link' => '[FILTERED]')
      expect(account.captain_documents.where(id: document.id)).not_to exist
    end
  end

  describe 'knowledge entry tools' do
    let(:entry) do
      create(
        :captain_assistant_response,
        account: account,
        assistant: assistant,
        question: 'How to pay?',
        answer: 'Use session=abc for secret billing flow.',
        documentable: document
      )
    end

    it 'lists and gets entries with redacted body' do
      entry

      list_payload = JSON.parse(Captain::Tools::Copilot::ListCaptainKnowledgeEntriesService.new(assistant, user: admin).execute(query: 'pay'))
      get_payload = JSON.parse(Captain::Tools::Copilot::GetCaptainKnowledgeEntryService.new(assistant, user: admin).execute(entry_id: entry.id))

      expect(list_payload['entries'].pluck('id')).to include(entry.id)
      expect(get_payload['entry']).to include('id' => entry.id, 'answer_preview' => '[FILTERED]', 'answer_bytes' => 40)
      expect(JSON.generate(get_payload)).not_to include('session=abc')
      expect(JSON.generate(get_payload)).not_to include('secret billing flow')
    end

    it 'allows attaching an entry to a same-account document owned by another assistant' do
      other_assistant = create(:captain_assistant, account: account)
      other_document = create(:captain_document, account: account, assistant: other_assistant)

      service = Captain::Tools::Copilot::CreateCaptainKnowledgeEntryService.new(assistant, user: admin)
      payload = JSON.parse(
        service.execute(
          assistant_id: assistant.id,
          question: 'Shared doc?',
          answer: 'Same account can attach.',
          document_id: other_document.id
        )
      )
      created_entry = account.captain_assistant_responses.find(payload['entry']['id'])

      expect(created_entry).to have_attributes(assistant_id: assistant.id, documentable: other_document)
    end

    it 'allows moving an entry to a same-account document owned by another assistant' do
      other_assistant = create(:captain_assistant, account: account)
      other_document = create(:captain_document, account: account, assistant: other_assistant)

      service = Captain::Tools::Copilot::UpdateCaptainKnowledgeEntryService.new(assistant, user: admin)
      payload = JSON.parse(
        service.execute(
          entry_id: entry.id,
          document_id: other_document.id
        )
      )

      expect(payload['entry']).to include('id' => entry.id)
      expect(entry.reload.documentable).to eq(other_document)
    end

    it 'creates, updates, and deletes manual entries with confirmation-gated services' do
      created_payload = JSON.parse(
        Captain::Tools::Copilot::CreateCaptainKnowledgeEntryService.new(assistant, user: admin).execute(
          assistant_id: assistant.id,
          question: 'What are working hours?',
          answer: 'We work 9-18.',
          status: 'approved',
          visibility: 'personal'
        )
      )
      created_entry = account.captain_assistant_responses.find(created_payload['entry']['id'])

      updated_payload = JSON.parse(
        Captain::Tools::Copilot::UpdateCaptainKnowledgeEntryService.new(assistant, user: admin).execute(
          entry_id: created_entry.id,
          answer: 'We work 10-19.',
          visibility: 'general'
        )
      )
      deleted_payload = JSON.parse(
        Captain::Tools::Copilot::DeleteCaptainKnowledgeEntryService.new(assistant, user: admin).execute(entry_id: created_entry.id)
      )

      expect(created_entry).to be_visibility_personal
      expect(updated_payload['entry']).to include('answer_preview' => '[FILTERED]', 'answer_bytes' => 14, 'visibility' => 'general')
      expect(JSON.generate(updated_payload)).not_to include('We work 10-19.')
      expect(deleted_payload['deleted_entry']).to include('id' => created_entry.id)
      expect(account.captain_assistant_responses.where(id: created_entry.id)).not_to exist
    end
  end

  describe 'registry exposure' do
    it 'registers knowledge admin tools as assistant-only with confirmation for writes', :aggregate_failures do
      read_tool_ids = %w[
        list_captain_knowledge_documents get_captain_knowledge_document
        list_captain_knowledge_entries get_captain_knowledge_entry
      ]
      write_tool_ids = %w[
        create_captain_knowledge_document update_captain_knowledge_document resync_captain_knowledge_document delete_captain_knowledge_document
        create_captain_knowledge_entry update_captain_knowledge_entry delete_captain_knowledge_entry
      ]

      read_tool_ids.each do |tool_id|
        definition = Captain::ToolRegistry.definition_for(tool_id)
        expect(definition.allowed_scopes).to eq([Captain::ToolAccess::SCOPE_ASSISTANT])
        expect(definition.requires_confirmation).not_to be(true)
        expect(definition.risk_level).to eq('low')
      end

      write_tool_ids.each do |tool_id|
        definition = Captain::ToolRegistry.definition_for(tool_id)
        expect(definition.allowed_scopes).to eq([Captain::ToolAccess::SCOPE_ASSISTANT])
        expect(definition.requires_confirmation).to be(true)
        expect(definition.risk_level).to eq('high')
        expect(definition.to_h[:selected_by_default]).to be(false)
      end

      expect(Captain::ToolRegistry.tools_for_scope(Captain::ToolAccess::SCOPE_AGENT).pluck(:id)).not_to include(*(read_tool_ids + write_tool_ids))
      expect(Captain::ToolRegistry.tools_for_scope(Captain::ToolAccess::SCOPE_ASSISTANT).pluck(:id)).to include(*(read_tool_ids + write_tool_ids))
    end
  end
end
# rubocop:enable RSpec/DescribeClass
