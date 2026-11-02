# frozen_string_literal: true

require 'json-schema'

class Captain::ShadowTraining::Comparison
  TEXT = { type: 'string', minLength: 1, maxLength: 2000 }.freeze
  SOURCE_REFS = { type: 'array', maxItems: 10, uniqueItems: true, items: { type: 'string', maxLength: 80 } }.freeze
  FAQ_SCHEMA = {
    type: 'object', additionalProperties: false, required: %w[question answer source_refs],
    properties: { question: TEXT.merge(maxLength: 500), answer: TEXT, source_refs: SOURCE_REFS.merge(minItems: 1) }
  }.freeze
  SCHEMA = {
    type: 'object', additionalProperties: false, required: %w[verdict explanation discrepancies faq_candidates],
    properties: {
      verdict: { type: 'string', enum: %w[equivalent discrepancy uncertain] }, explanation: TEXT,
      discrepancies: {
        type: 'array', maxItems: 10, items: {
          type: 'object', additionalProperties: false, required: %w[description source_refs],
          properties: { description: TEXT, source_refs: SOURCE_REFS }
        }
      },
      faq_candidates: { type: 'array', maxItems: 1, items: FAQ_SCHEMA }
    }
  }.freeze

  def self.validate!(value, facts:)
    raise ArgumentError, 'invalid_comparison_schema' unless JSON::Validator.validate(SCHEMA, value)

    validate_verdict!(value)
    validate_sources!(value, facts)
    validate_faq_privacy!(value)
    value
  end

  def self.validate_verdict!(value)
    raise ArgumentError, 'invalid_discrepancy_verdict' if (value['verdict'] == 'discrepancy') != value['discrepancies'].any?
    raise ArgumentError, 'invalid_faq_verdict' if value['verdict'] != 'discrepancy' && value['faq_candidates'].any?
  end

  def self.validate_sources!(value, facts)
    allowed = facts.map { |fact| fact.fetch('ref') }
    references = (value['discrepancies'] + value['faq_candidates']).flat_map { |item| item.fetch('source_refs') }
    raise ArgumentError, 'unknown_comparison_source' unless (references - allowed).empty?
  end

  def self.validate_faq_privacy!(value)
    value['faq_candidates'].each do |faq|
      text = [faq['question'], faq['answer']].join(' ')
      if text.match?(Llm::PiiSessionPseudonymizer::TOKEN_PATTERN) || text.match?(Llm::IinTokenVault::TOKEN_PATTERN)
        raise ArgumentError, 'patient_data_in_faq_candidate'
      end
    end
  end
end
