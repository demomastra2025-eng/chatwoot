# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::CaptainResponseContentNormalizer do
  let(:schema) { Captain::ResponseSchema }

  describe '.apply_defaults' do
    it 'fills the mode, the reasoning and the artifact list and adds no handoff field' do
      payload = described_class.apply_defaults(schema, { 'response' => 'Готово.' })

      expect(payload).to eq(
        'response' => 'Готово.',
        'response_mode' => 'reply',
        'reasoning' => described_class::DEFAULT_REASONING,
        'artifact_ids' => []
      )
    end

    it 'drops the handoff text and reason a model still writes, whatever their value' do
      payload = described_class.apply_defaults(
        schema,
        { 'response' => 'Готово.', 'reasoning' => 'FAQ.', 'handoff_message' => 'Model text', 'handoff_reason' => nil }
      )

      expect(payload.keys).to match_array(%w[response response_mode reasoning artifact_ids])
    end

    it 'leaves the content of another schema alone' do
      other = Class.new(RubyLLM::Schema) { string :message }
      content = { 'message' => 'Done', 'handoff_message' => 'kept' }

      expect(described_class.apply_defaults(other, content)).to eq(content)
    end
  end

  describe '.plain_text_fallback' do
    it 'wraps plain text in the four Captain fields only' do
      payload = described_class.plain_text_fallback(schema, "<think>x</think>\nГотово.")

      expect(payload).to eq(
        response: 'Готово.', response_mode: 'reply', reasoning: described_class::DEFAULT_REASONING, artifact_ids: []
      )
    end
  end
end
