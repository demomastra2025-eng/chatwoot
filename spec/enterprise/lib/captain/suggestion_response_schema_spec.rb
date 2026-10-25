# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::SuggestionResponseSchema do
  let(:account) { create(:account, locale: 'ru') }
  let(:assistant) { create(:captain_assistant, account: account, active: true) }

  def system_prompt(agent, source)
    agent.get_system_prompt(OpenStruct.new(context: { state: { source: source } }))
  end

  describe 'the schema' do
    it 'adds a note for the operator and the human mode to the fields of the live schema' do
      suggestion_fields = described_class.new.to_json_schema.dig(:schema, :properties).keys.map(&:to_s)
      live_fields = Captain::ResponseSchema.new.to_json_schema.dig(:schema, :properties).keys.map(&:to_s)

      expect(suggestion_fields).to match_array(live_fields + ['operator_note'])
      expect(described_class::RESPONSE_MODES).to eq(%w[reply suppress human])
      expect(Captain::ResponseSchema::RESPONSE_MODES).to eq(%w[reply suppress])
    end

    it 'is the output of the agent of a reply suggestion only' do
      expect(assistant.agent(suggestion_tools: true).response_schema).to eq(described_class)
      expect(assistant.agent.response_schema).to eq(Captain::ResponseSchema)
      expect(assistant.agent(read_only_tools: true).response_schema).to eq(Captain::ResponseSchema)
    end
  end

  describe 'the prompt' do
    it 'tells the agent of a suggestion to answer human or suppress with a note in the language of the operator' do
      prompt = system_prompt(assistant.agent(suggestion_tools: true), 'reply_suggestion')

      expect(prompt).to include('set response_mode to human', 'set response_mode to suppress', 'operator_note')
      expect(prompt).to include('in russian')
      expect(prompt).not_to include('say that you will clarify the information')
    end

    it 'gives a council part of a suggestion no rule about response_mode or operator_note: it answers with the result of a part' do
      context = OpenStruct.new(context: { state: { source: 'reply_suggestion' }, part_run: true })
      prompt = assistant.agent(suggestion_tools: true).get_system_prompt(context)

      expect(prompt).not_to include('response_mode', 'operator_note')
      expect(prompt).to include('pending_operator_approval', 'end your part as the rules of your part below say')
    end

    it 'names the # Clinic block in the first rule of a suggestion and of a council part, and each still ends in its own way' do
      account.update!(captain_clinic_context: 'Клиника: МО «Тест».')
      draft = system_prompt(assistant.agent(suggestion_tools: true), 'reply_suggestion')
      part = assistant.agent(suggestion_tools: true).get_system_prompt(
        OpenStruct.new(context: { state: { source: 'reply_suggestion' }, part_run: true })
      )

      expect([draft, part]).to all(include('Answer from # Clinic, the clinic instructions, the data below', "# Clinic\nКлиника: МО «Тест»."))
      expect(draft).to include('do not draft a reply: set response_mode to human')
      expect(draft).not_to include('end your part as the rules of your part below say')
      expect(part).to include('end your part as the rules of your part below say')
      expect(part).not_to include('response_mode')

      account.update!(captain_clinic_context: '')
      expect(system_prompt(assistant.reload.agent(suggestion_tools: true), 'reply_suggestion')).not_to include('# Clinic,')
    end

    it 'does not give the live agent any of it' do
      prompt = system_prompt(assistant.agent, 'incoming_message')

      expect(prompt).not_to include('operator_note')
      expect(prompt).not_to include('response_mode to human')
    end
  end

  describe Llm::CaptainResponseContentNormalizer do
    it 'treats the suggestion schema as a Captain schema' do
      expect(described_class.applicable?(Captain::SuggestionResponseSchema)).to be(true)
      expect(described_class.applicable?(Captain::ResponseSchema)).to be(true)
    end

    it 'fills an empty note for the suggestion schema, and adds none to the live schema' do
      suggestion = described_class.apply_defaults(Captain::SuggestionResponseSchema, { 'response' => 'Готово.' })
      live = described_class.apply_defaults(Captain::ResponseSchema, { 'response' => 'Готово.' })

      expect(suggestion).to include('operator_note' => '', 'response_mode' => 'reply', 'response' => 'Готово.')
      expect(suggestion.keys).to match_array(%w[patient_language response response_mode operator_note reasoning artifact_ids])
      expect(live).not_to have_key('operator_note')
    end

    it 'keeps the note of the model, and blanks a null one' do
      kept = described_class.apply_defaults(
        Captain::SuggestionResponseSchema, { 'response' => '', 'response_mode' => 'human', 'operator_note' => 'Решает врач.' }
      )
      nulled = described_class.apply_defaults(Captain::SuggestionResponseSchema, { 'response' => 'Ок', 'operator_note' => nil })

      expect(kept).to include('response_mode' => 'human', 'operator_note' => 'Решает врач.')
      expect(nulled['operator_note']).to eq('')
    end

    it 'wraps a plain text answer of a suggestion with an empty note' do
      expect(described_class.plain_text_fallback(Captain::SuggestionResponseSchema, 'Готово.')).to include(operator_note: '', response: 'Готово.')
      expect(described_class.plain_text_fallback(Captain::ResponseSchema, 'Готово.')).not_to have_key(:operator_note)
    end
  end
end
