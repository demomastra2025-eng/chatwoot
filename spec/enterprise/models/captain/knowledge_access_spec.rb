require 'rails_helper'

RSpec.describe Concerns::CaptainKnowledgeAccess do
  let(:account) { create(:account) }
  let(:first_agent) { create(:captain_assistant, account: account) }
  let(:second_agent) { create(:captain_assistant, account: account) }
  let(:third_agent) { create(:captain_assistant, account: account) }
  let(:embedding) { Array.new(Captain::Llm::EmbeddingService::VECTOR_DIMENSIONS, 0.1) }

  before do
    allow(Captain::Llm::EmbeddingService).to receive(:new)
      .with(account_id: account.id).and_return(instance_double(Captain::Llm::EmbeddingService, get_embedding: embedding))
  end

  def selected_document(**attributes)
    create(:captain_document, account: account, assistant: nil, visibility: :personal,
                              allowed_assistant_ids: [first_agent.id, second_agent.id], **attributes)
  end

  def selected_response(**attributes)
    create(:captain_assistant_response, account: account, assistant: nil, visibility: :personal,
                                        allowed_assistant_ids: [first_agent.id, second_agent.id], embedding: embedding,
                                        question: 'Shared refund policy', answer: 'Refund within thirty days', **attributes)
  end

  it 'shares one FAQ with selected agents through exact, lexical and semantic retrieval' do
    material = selected_response
    [first_agent, second_agent].each do |agent|
      expect(Captain::AssistantResponse.exact_search(material.question, account_id: account.id, assistant_id: agent.id)).to include(material)
      expect(Captain::AssistantResponse.lexical_search('refund', account_id: account.id, assistant_id: agent.id)).to include(material)
      expect(Captain::AssistantResponse.search('refund', account_id: account.id, assistant_id: agent.id)).to include(material)
    end
    expect(Captain::AssistantResponse.exact_search(material.question, account_id: account.id, assistant_id: third_agent.id)).to be_empty
    expect(Captain::AssistantResponse.lexical_search('refund', account_id: account.id, assistant_id: third_agent.id)).to be_empty
    expect(Captain::AssistantResponse.search('refund', account_id: account.id, assistant_id: third_agent.id)).to be_empty
    expect(Captain::AssistantResponse.visible_to_assistant(nil)).not_to include(material)
  end

  it 'shares documents and indexed chunks with exactly the selected agents' do
    document = selected_document
    chunk = create(:captain_document_chunk, document: document, account: account, assistant: nil,
                                           embedding: embedding, embedding_status: :indexed)
    [first_agent, second_agent].each do |agent|
      expect(Captain::Document.visible_to_assistant(agent.id)).to include(document)
      expect(Captain::DocumentChunk.visible_to_assistant(agent.id)).to include(chunk)
      expect(Captain::DocumentChunk.search('refund', account_id: account.id, assistant_id: agent.id)).to include(chunk)
    end
    expect(Captain::Document.visible_to_assistant(third_agent.id)).not_to include(document)
    expect(Captain::DocumentChunk.visible_to_assistant(third_agent.id)).not_to include(chunk)
    expect(Captain::DocumentChunk.search('refund', account_id: account.id, assistant_id: third_agent.id)).to be_empty
  end

  it 'applies the same FAQ grant boundary to documentation tool lexical fallbacks' do
    faq = selected_response
    [first_agent, second_agent, third_agent].each do |agent|
      search_tool = Captain::Tools::SearchDocumentationService.new(agent)
      reply_tool = Captain::Tools::SearchReplyDocumentationService.new(account: account, assistant: agent)
      [search_tool, reply_tool].each do |tool|
        results = tool.send(:lexical_fallback_responses, 'refund')
        if agent == third_agent
          expect(results).not_to include(faq)
        else
          expect(results).to include(faq)
        end
      end
    end
  end

  it 'uses source grants for derived pages and their generated FAQ fallback' do
    source = selected_document
    derived = create(:captain_document, account: account, assistant: nil, visibility: :personal,
                                       metadata: { firecrawl: { root_document_id: source.id } })
    faq = create(:captain_assistant_response, account: account, assistant: nil, documentable: derived,
                                            visibility: :personal, question: 'Shared refund policy', embedding: embedding)
    chunk = create(:captain_document_chunk, account: account, assistant: nil, document: derived)

    expect(Captain::Document.visible_to_assistant(second_agent.id)).to include(source, derived)
    expect(Captain::AssistantResponse.exact_search(faq.question, account_id: account.id, assistant_id: second_agent.id)).to include(faq)
    expect(Captain::AssistantResponse.lexical_search('refund', account_id: account.id, assistant_id: second_agent.id)).to include(faq)
    expect(Captain::DocumentChunk.visible_to_assistant(second_agent.id)).to include(chunk)
    expect(faq.allowed_assistant_ids).to contain_exactly(first_agent.id, second_agent.id)

    source.update!(allowed_assistant_ids: [first_agent.id])
    expect(Captain::Document.visible_to_assistant(second_agent.id)).not_to include(source, derived)
    expect(Captain::AssistantResponse.visible_to_assistant(second_agent.id)).not_to include(faq)
    expect(Captain::DocumentChunk.visible_to_assistant(second_agent.id)).not_to include(chunk)
  end

  it 'does not expose a private source through a generally visible FAQ or separately granted FAQ' do
    document = create(:captain_document, account: account, assistant: first_agent, visibility: :personal)
    faq = create(:captain_assistant_response, account: account, assistant: nil, documentable: document, visibility: :general)
    faq.update!(visibility: :personal, allowed_assistant_ids: [second_agent.id])

    expect(Captain::AssistantResponse.visible_to_assistant(second_agent.id)).not_to include(faq)
    expect(Captain::AssistantResponse.visible_to_assistant(third_agent.id)).not_to include(faq)
  end

  it 'keeps generated FAQs aligned when a legacy document owner is replaced by selected agents' do
    document = create(:captain_document, account: account, assistant: first_agent, visibility: :personal)
    faq = create(:captain_assistant_response, account: account, assistant: first_agent, documentable: document,
                                            visibility: :personal, question: 'Legacy refund policy')

    document.update!(assistant: nil, allowed_assistant_ids: [second_agent.id])

    expect(faq.reload.assistant_id).to be_nil
    expect(Captain::AssistantResponse.exact_search(faq.question, account_id: account.id, assistant_id: second_agent.id)).to include(faq)
    expect(Captain::AssistantResponse.visible_to_assistant(first_agent.id)).not_to include(faq)
    expect(Captain::AssistantResponse.visible_to_assistant(third_agent.id)).not_to include(faq)
  end

  it 'keeps the legacy owner authorized alongside extra grants' do
    material = selected_response(assistant: first_agent, allowed_assistant_ids: [second_agent.id])

    expect(material.allowed_assistant_ids).to contain_exactly(first_agent.id, second_agent.id)
    expect(Captain::AssistantResponse.visible_to_assistant(first_agent.id)).to include(material)
    expect(Captain::AssistantResponse.visible_to_assistant(second_agent.id)).to include(material)
    expect(Captain::AssistantResponse.visible_to_assistant(third_agent.id)).not_to include(material)
  end

  it 'rejects an explicit empty selection and cross-account selections' do
    empty = build(:captain_document, account: account, assistant: nil, visibility: :personal, allowed_assistant_ids: [])
    foreign_agent = create(:captain_assistant)
    foreign = build(:captain_assistant_response, account: account, assistant: nil, visibility: :personal,
                                               allowed_assistant_ids: [foreign_agent.id])

    expect(empty).not_to be_valid
    expect(empty.errors[:allowed_assistant_ids]).to include('must include at least one agent for personal knowledge')
    expect(foreign).not_to be_valid
    expect(foreign.errors[:allowed_assistant_ids]).to include('must contain agents from the same account')
  end

  it 'retains legacy workspace-personal access without widening selected material when its last grant is removed' do
    legacy = create(:captain_document, account: account, assistant: nil, visibility: :personal)
    selected = selected_document(allowed_assistant_ids: [first_agent.id])
    selected.knowledge_grants.destroy_all

    expect(Captain::Document.visible_to_assistant(third_agent.id)).to include(legacy)
    expect(Captain::Document.visible_to_assistant(third_agent.id)).not_to include(selected)
    expect(Captain::Document.visible_to_assistant(nil)).not_to include(selected)
  end

  it 'clears selected grants when a material is made general' do
    material = selected_response
    material.update!(visibility: :general)

    expect(material.knowledge_grants).to be_empty
    expect(material.allowed_assistant_ids).to eq([])
    expect(Captain::AssistantResponse.visible_to_assistant(third_agent.id)).to include(material)
  end
end
