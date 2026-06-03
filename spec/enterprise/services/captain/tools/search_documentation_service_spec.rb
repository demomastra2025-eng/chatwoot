require 'rails_helper'

RSpec.describe Captain::Tools::SearchDocumentationService do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:service) { described_class.new(assistant) }

  before do
    translate_service = instance_double(Captain::Llm::TranslateQueryService)
    allow(Captain::Llm::TranslateQueryService).to receive(:new).with(account: account).and_return(translate_service)
    allow(translate_service).to receive(:translate).and_return('visibilityscope')
  end

  it 'shares general chunks but hides another assistant personal chunks' do
    other_assistant = create(:captain_assistant, account: account)
    general_document = create(:captain_document, account: account, assistant: other_assistant, visibility: :general)
    personal_document = create(:captain_document, account: account, assistant: other_assistant, visibility: :personal)
    general_chunk = general_document.document_chunks.create!(
      account: account,
      assistant: other_assistant,
      chunk_index: 0,
      content: 'Shared documentation source'
    )
    personal_chunk = personal_document.document_chunks.create!(
      account: account,
      assistant: other_assistant,
      chunk_index: 0,
      content: 'Private documentation source'
    )
    allow(Captain::DocumentChunk).to receive(:search).and_return(Captain::DocumentChunk.where(id: [general_chunk.id, personal_chunk.id]))

    result = service.execute(query: 'visibilityscope')

    expect(result).to include('Shared documentation source')
    expect(result).not_to include('Private documentation source')
  end

  it 'shares general FAQ entries but hides another assistant personal entries during lexical fallback' do
    other_assistant = create(:captain_assistant, account: account)
    create(
      :captain_assistant_response,
      assistant: other_assistant,
      account: account,
      question: 'visibilityscope shared',
      answer: 'Shared documentation answer',
      visibility: :general,
      status: :approved
    )
    create(
      :captain_assistant_response,
      assistant: other_assistant,
      account: account,
      question: 'visibilityscope private',
      answer: 'Private documentation answer',
      visibility: :personal,
      status: :approved
    )
    allow(Captain::DocumentChunk).to receive(:search).and_return(Captain::DocumentChunk.none)

    result = service.execute(query: 'visibilityscope')

    expect(result).to include('Shared documentation answer')
    expect(result).not_to include('Private documentation answer')
  end

  it 'degrades to lexical fallback when semantic documentation lookup times out' do
    create(
      :captain_assistant_response,
      assistant: assistant,
      account: account,
      question: 'visibilityscope timeout',
      answer: 'Timeout fallback answer',
      status: :approved
    )
    allow(Captain::DocumentChunk).to receive(:search).and_raise(Timeout::Error, 'execution expired')

    result = service.execute(query: 'visibilityscope')

    expect(result).to include('Timeout fallback answer')
    expect(result).not_to include('temporarily unavailable')
  end

  it 'bounds semantic documentation lookup and degrades to lexical fallback on timeout' do
    create(
      :captain_assistant_response,
      assistant: assistant,
      account: account,
      question: 'visibilityscope bounded timeout',
      answer: 'Bounded timeout fallback answer',
      status: :approved
    )
    expect(Timeout).to receive(:timeout)
      .with(described_class::SEMANTIC_LOOKUP_TIMEOUT_SECONDS)
      .and_raise(Timeout::Error, 'execution expired')

    result = service.execute(query: 'visibilityscope')

    expect(result).to include('Bounded timeout fallback answer')
    expect(result).not_to include('temporarily unavailable')
  end
end
