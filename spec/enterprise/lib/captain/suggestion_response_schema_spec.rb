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
      expect(prompt).to include('When only a part of the request needs staff and the sources answer the rest',
                                'unless the draft leaves a part of the request to staff: then it names that part.')
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

    describe 'the rules of a suggestion before it hands over, asks or stays silent' do
      let(:lookup_rule) do
        '- Before you decide that the sources have no answer, call the tools the clinic instructions and this request need: ' \
          'a slot search for a doctor, a booking or free times, search_scheduling_services for a price, faq_lookup for documents ' \
          'and certificates. When they return several tariffs or prices, list each with its condition instead of handing over; when it ' \
          'is unclear which service or visit the patient means, ask the patient.'
      end
      let(:slots_first_rule) do
        'for a booking or a question about a doctor or free times, first search the free times (of the branch\'s doctors of that ' \
          'specialty when no doctor is named) and ask only what they cannot settle.'
      end
      let(:future_rule) do
        'Offer only start times that a slot search returned in this run, exactly as returned and all later than Now. Opening ' \
          'hours or a last booking time in the clinic texts ("последняя запись 19:00") are not free times: never offer a time the search ' \
          'did not return. Name a date only with the times the search returned for that very date. Never say that a time is taken, not ' \
          'free or has no window unless search_available_slots for that exact time (from = to) returned no start in this run: the times ' \
          'of a day are a sample (more counts the rest), so a time missing from the list may be free.'
      end
      # Suggestion eval 26.10: a card was prepared at 14:20 while the search listed 14:30 and later.
      let(:exact_time_rule) do
        'For an exact time (one the patient named, or chose from times an earlier reply offered), first call search_available_slots with ' \
          "the specialist's resource_ids and from = to = that time; when it returns that start and all required details are known, call " \
          'the booking or reschedule tool with exactly that start to queue the operator approval card, and draft the reply with the ' \
          'exact date, time and specialist. The platform refuses a booking or a move to a start that no search of this run returned.'
      end
      # Suggestion eval 26.10: Intermedical 113 handed catalog prices to staff because the schedule was not confirmed, and agents
      # booked visits on a closing «Спасибо».
      let(:price_rule) do
        'A catalog price is an answer even when the schedule is not confirmed (SCHEDULE_NOT_CONFIRMED, degraded availability) or has no ' \
          'free times: give the price and say only that the free times will be confirmed; never hand a price question to staff because ' \
          'of the schedule.'
      end
      let(:closing_thanks_rule) do
        'A thanks, ok or confirmation that closes a topic (after prices or information, a reminder, a time already agreed, or a ' \
          'visit already booked or already prepared) asks for no action: never call create_appointment, update_appointment or ' \
          'cancel_appointment for it; book only on a clear request or a clear yes to an offered time.'
      end
      let(:silence_rule) do
        '(only thanks, ok or an emoji with no doctor, service, date, time or question in them, or staff already answered them), set ' \
          'response_mode to suppress'
      end
      let(:thanks_request_rule) { 'A thanks that also names a doctor, a service, a date, a time or a question is a request: answer it.' }

      it 'looks up before handing over, searches free times before asking, lists tariffs, asks when unclear and offers searched future times' do
        draft = system_prompt(assistant.agent(suggestion_tools: true), 'reply_suggestion')

        expect(draft).to include(lookup_rule, slots_first_rule, future_rule, exact_time_rule, silence_rule, thanks_request_rule,
                                 price_rule, closing_thanks_rule)
        expect(draft.scan('search_scheduling_services').size).to eq(1)
        expect(draft).not_to include('For a price, search_scheduling_services before saying no answer is available.')
      end

      it 'gives a council part the same lookups but no rule to stay silent (a part has its own status for that)' do
        part = assistant.agent(suggestion_tools: true).get_system_prompt(
          OpenStruct.new(context: { state: { source: 'reply_suggestion' }, part_run: true })
        )

        expect(part).to include(lookup_rule, slots_first_rule, future_rule, exact_time_rule, price_rule, closing_thanks_rule)
        expect(part).not_to include(silence_rule, thanks_request_rule)
      end

      it 'leaves the rules of a live turn as they are' do
        live = system_prompt(assistant.agent, 'incoming_message')

        expect(live).to include('- For a price, search_scheduling_services before saying no answer is available. For documents and ' \
                                'certificates, use faq_lookup first. A catalog price is an answer even when the schedule is not confirmed.',
                                '- Offer only start times a slot search returned, exactly as returned; opening hours or a last booking ' \
                                'time in the clinic texts are not free times.',
                                'A thanks, ok or confirmation that closes a topic (after prices or information, a reminder, a time ' \
                                'already agreed, or a visit already booked), also one that says the patient will come ' \
                                '("спасибо, буду", "рахмет, келемін"), asks for no action: never book, change or cancel anything for it.')
        expect(live).not_to include(lookup_rule, slots_first_rule, future_rule, exact_time_rule, thanks_request_rule, price_rule,
                                    closing_thanks_rule)
      end
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
