# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::CaptainResponseContentNormalizer do
  let(:schema) { Captain::ResponseSchema }

  describe '.apply_defaults' do
    it 'fills the language, the mode, the reasoning and the artifact list and adds no handoff field' do
      payload = described_class.apply_defaults(schema, { 'response' => 'Готово.' })

      expect(payload).to eq(
        'patient_language' => '',
        'response' => 'Готово.',
        'response_mode' => 'reply',
        'reasoning' => described_class::DEFAULT_REASONING,
        'artifact_ids' => []
      )
    end

    it 'keeps the language the model named and blanks one that is missing or null' do
      named = described_class.apply_defaults(schema, { 'patient_language' => 'Kazakh', 'response' => 'Дайын.' })
      missing = described_class.apply_defaults(schema, { 'patient_language' => nil, 'response' => 'Дайын.' })

      expect(named['patient_language']).to eq('Kazakh')
      expect(missing['patient_language']).to eq('')
    end

    it 'drops the handoff text and reason a model still writes, whatever their value' do
      payload = described_class.apply_defaults(
        schema,
        { 'response' => 'Готово.', 'reasoning' => 'FAQ.', 'handoff_message' => 'Model text', 'handoff_reason' => nil }
      )

      expect(payload.keys).to match_array(%w[patient_language response response_mode reasoning artifact_ids])
    end

    it 'leaves the content of another schema alone' do
      other = Class.new(RubyLLM::Schema) { string :message }
      content = { 'message' => 'Done', 'handoff_message' => 'kept' }

      expect(described_class.apply_defaults(other, content)).to eq(content)
    end
  end

  describe '.plain_text_fallback' do
    it 'wraps plain text in the five Captain fields only, with no language' do
      payload = described_class.plain_text_fallback(schema, "<think>x</think>\nГотово.")

      expect(payload).to eq(
        patient_language: '', response: 'Готово.', response_mode: 'reply', reasoning: described_class::DEFAULT_REASONING, artifact_ids: []
      )
    end

    it 'rejects canned provider safety refusals instead of wrapping them as customer replies' do
      refusals = [
        "I'm sorry, but I cannot assist with that request.",
        "<think>policy check</think>\nI’m sorry, I can’t assist with that.",
        'I cannot fulfill this request.'
      ]

      refusals.each do |refusal|
        expect(described_class.plain_text_fallback(schema, refusal)).to be_nil
        expect(described_class.plain_text_fallback(Captain::SuggestionResponseSchema, refusal)).to be_nil
      end
    end
  end

  describe '.provider_refusal?' do
    it 'detects straight-quote, curly-quote and reasoning-prefixed provider safety refusals' do
      refusals = [
        "I'm sorry, but I cannot assist with that request.",
        'I’m sorry, but I can’t assist with that request.',
        "Sorry, I can't help with that.",
        'I apologize, but I cannot fulfill this request.',
        'I cannot comply with this request.',
        "As an AI assistant, I'm unable to assist with your request.",
        "[Thu 29.10 16:30] I'm sorry, but I cannot assist with that request.",
        "<think>safety</think>\nI'm sorry, but I cannot assist with that request. If you have other questions, feel free to ask."
      ]

      expect(refusals).to all(satisfy { |text| described_class.provider_refusal?(text) })
      expect(refusals).to all(satisfy { |text| described_class.invalid_public_response?(text) })
    end

    it 'does not flag normal clinic apologies or domain explanations' do
      clinic_replies = [
        "I'm sorry, I cannot book Dr. Ivanov on Sunday.",
        "I'm sorry, I cannot assist with booking on Sunday because the clinic is closed.",
        'Sorry, I cannot provide MRI prices without knowing which zone you need.',
        'Извините, запись к урологу на воскресенье закрыта.',
        nil,
        123
      ]

      clinic_replies.each do |reply|
        expect(described_class.provider_refusal?(reply)).to be(false)
      end
    end
  end
end
