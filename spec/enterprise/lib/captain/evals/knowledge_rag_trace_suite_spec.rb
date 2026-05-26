# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::Evals::KnowledgeRagTraceSuite do
  it 'passes the default deterministic Knowledge/RAG trace cases' do
    result = described_class.new.call

    expect(result.to_h).to include(
      suite_id: 'captain.knowledge_rag_trace',
      total_count: 3,
      passed_count: 3,
      failed_count: 0,
      error_count: 0,
      status: 'pass'
    )
    expect(result.to_h[:cases]).to include(
      include(id: 'knowledge.semantic_chunk_success', status: 'pass'),
      include(id: 'knowledge.semantic_failure_degrades_to_lexical', status: 'pass'),
      include(id: 'knowledge.explicit_nonsemantic_lexical_is_not_degraded', status: 'pass')
    )
  end

  it 'fails lexical success without semantic chunk trace or indexed chunk ids' do
    Dir.mktmpdir do |dir|
      cases_path = Pathname.new(dir).join('knowledge_rag_trace.yml')
      cases_path.write(
        <<~YAML
          cases:
            - id: unsafe.lexical_success
              result:
                lookup_strategy: lexical
                matches:
                  - type: faq_response
                    id: 1
                retrieval_trace:
                  strategy: lexical
                  degraded: false
                  semantic_attempted: true
                  match_count: 1
              expected:
                strategy: semantic_chunk
                degraded: false
                semantic_attempted: true
                min_match_count: 1
                require_document_chunk_ids: true
                require_indexed_chunks: true
                forbid_lexical_success: true
        YAML
      )

      result = described_class.new(cases_path: cases_path).call

      expect(result.to_h).to include(total_count: 1, passed_count: 0, failed_count: 1, status: 'fail')
      expect(result.to_h[:cases].first[:failures].join(' ')).to include(
        'lookup_strategy mismatch',
        'trace strategy mismatch',
        'document_chunk_ids missing',
        'indexed chunk count missing',
        'semantic success degraded to lexical'
      )
    end
  end
end
