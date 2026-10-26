# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::ReplySuggestion::DraftTimes do
  let(:cache_key) { Captain::Runtime::ToolWrapper::SUGGESTION_READ_CACHE_KEY }
  let(:slots) do
    JSON.generate('slots' => [{ 'starts_at' => '2026-10-27T19:30:00+05:00', 'resource_name' => 'Елубаев Е.' },
                              { 'starts_at' => '2026-10-27T19:50:00+05:00', 'resource_name' => 'Елубаев Е.' }],
                  'last_booking_time' => '19:00')
  end
  let(:faq) { 'Филиал на Байтурсынова работает до 20:00, последняя запись 19:00.' }
  let(:context) do
    {
      captain_v2_completed_tool_names: %w[faq_lookup search_available_slots],
      cache_key => { 'digest-1' => { result: slots, tool: 'search_available_slots' }, 'digest-2' => { result: faq, tool: 'faq_lookup' } },
      conversation_history: [{ role: :user, content: '[Mon 26.10 17:02] Здравствуйте, завтра вечером к ЛОРу можно?' }],
      captain_v2_current_input: 'А в 18:00 есть?'
    }
  end

  # Suggestion eval 26.10, Sezim (Байтурсынова): the clinic text says «последняя запись 19:00», the search returned 19:30 and 19:50,
  # and the draft offered 19:00.
  it 'names the time the draft offers that the slot search did not return, even when a clinic text names it' do
    draft = 'Завтра свободно в 19:00 и 19:30 у Елубаева. Записать вас?'

    expect(described_class.unverified(draft: draft, context: context)).to eq(['19:00'])
  end

  it 'accepts the searched times, the times of the dialog and of the message, in any spelling, and leaves the send stamps out' do
    draft = 'В 18:00 мест нет, свободно 19:30 и 19:50 (9:30 утром тоже нет). Вы писали в 17:02?'

    expect(described_class.unverified(draft: draft, context: context)).to eq(%w[09:30 17:02])
  end

  it 'checks only a run that searched free times' do
    without_search = context.merge(captain_v2_completed_tool_names: %w[faq_lookup])

    expect(described_class.unverified(draft: 'Ждём вас в 19:00.', context: without_search)).to eq([])
  end

  it 'reads a context with string keys and results kept as data' do
    stringified = { 'captain_v2_completed_tool_names' => ['search_available_slots'],
                    cache_key.to_s => { 'd' => { 'result' => JSON.parse(slots), 'tool' => 'search_available_slots' } } }

    expect(described_class.unverified(draft: 'Свободно 19:50 и 20:10.', context: stringified)).to eq(['20:10'])
  end

  it 'never reads a date or a price as a time' do
    expect(described_class.times('Запись 27.10 в 19:30, 12 000 ₸, кабинет 2:3, 25:00')).to eq(['19:30'])
  end
end
