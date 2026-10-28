# frozen_string_literal: true

require 'rails_helper'

# Review of quality-fixes-1 (M4): the platform rules say that a visit is cancelled or moved only from a tool and that there is never
# "nothing to cancel"; nothing in the code stopped a draft that said it. The draft is checked by its words and named to the manager.
RSpec.describe Captain::ReplySuggestion::DraftClaims do
  def unsupported(draft, tools = [], done = [])
    described_class.unsupported(draft: draft, context: { captain_v2_completed_tool_names: tools, done_actions: done })
  end

  describe 'a visit said to be cancelled or moved' do
    it 'is named when the run did not call the tool that does it, in Russian and in Kazakh' do
      ['Ваша запись отменена.', 'Я отменила вашу запись на завтра.', 'Запись перенесена на пятницу в 10:00.', 'Перенесла вас на 11:00.',
       'Жазбаңыз жойылды.', 'Запись ауыстырылды.'].each do |draft|
        expect(unsupported(draft, %w[search_available_slots faq_lookup])).not_to be_empty, draft
      end
      expect(unsupported('Ваша запись отменена.', %w[search_available_slots])).to eq(%w[cancelled])
      expect(unsupported('Запись перенесена на пятницу.', %w[search_available_slots])).to eq(%w[moved])
      expect(unsupported('Запись отменена, а новая перенесена на пятницу.', [])).to match_array(%w[cancelled moved])
    end

    it 'is not named when the run called cancel_appointment or update_appointment, a card that waits for the operator included' do
      expect(unsupported('Я отменила вашу запись на завтра.', %w[list_my_appointments cancel_appointment])).to eq([])
      expect(unsupported('Запись перенесена на пятницу в 10:00.', %w[search_available_slots update_appointment])).to eq([])
    end

    it 'is not named when an earlier reply of the conversation did it (the actions the agents already did)' do
      done = [{ 'tool' => 'cancel_appointment', 'label' => 'Cancellation requested', 'text' => 'Dr X' }]

      expect(unsupported('Ваша запись отменена.', [], done)).to eq([])
    end

    it 'accepts a state read from an appointment lookup, but not a move or an action claim' do
      expect(unsupported('Ваша запись отменена.', %w[list_my_appointments])).to eq([])
      expect(unsupported('Я отменила вашу запись.', %w[list_my_appointments])).to eq(%w[cancelled])
      expect(unsupported('Запись перенесена.', %w[list_my_appointments])).to eq(%w[moved])
    end

    it 'does not take an offer, a question, a future, a negation or the data of another thing for a claim' do
      ['Хотите, я отменю запись?', 'Отменить запись на завтра?', 'Запись будет перенесена после подтверждения.', 'Я не отменяла вашу запись.',
       'Если нужно, можно перенести запись.', 'Запись отменить можно за сутки.', 'Мы готовим отмену записи.'].each do |draft|
        expect(unsupported(draft)).to eq([]), draft
      end
    end
  end

  describe 'an absence of an appointment' do
    it 'is named whatever the lookups returned: the rules forbid saying it' do
      ['У вас нет записи.', 'К сожалению, записей нет.', 'Записи нет.', 'У вас нет предстоящих записей', 'Запись не найдена.',
       'Я не нашла вашу запись.', 'Отменять нечего.', 'Нечего отменять — на этот номер ничего не записано.', 'Ничего не записано',
       'Сізде жазба жоқ.', 'Сіз жазылмағансыз.'].each do |draft|
        expect(unsupported(draft, %w[list_my_appointments search_appointments])).to eq(%w[no_appointment]), draft
      end
    end

    it 'does not take a talk of a free time, a doctor or a price for an absence' do
      ['Свободных окон нет, но есть 14:00.', 'Запись на 14:00 возможна.', 'Записи на УЗИ ведёт регистратура.', 'Нет противопоказаний.',
       'Для записи нужен ИИН.'].each do |draft|
        expect(unsupported(draft)).to eq([]), draft
      end
    end
  end

  it 'checks nothing for an empty draft or a context without tools' do
    expect(unsupported('')).to eq([])
    expect(described_class.unsupported(draft: nil, context: nil)).to eq([])
    expect(described_class.unsupported(draft: 'Ваша запись отменена.', context: {})).to eq(%w[cancelled])
  end

  it 'reads the tool names with string keys and in their canonical form' do
    context = { 'captain_v2_completed_tool_names' => ['cancel_appointment'] }

    expect(described_class.unsupported(draft: 'Ваша запись отменена.', context: context)).to eq([])
  end

  describe '.unsupported_completed_actions' do
    def completed(draft, records: [], cards: [])
      described_class.unsupported_completed_actions(
        draft: draft, context: { captain_v2_completed_tool_results: records, captain_suggestion_pending_actions: cards }
      )
    end

    it 'blocks unsupported booking, cancellation and move claims in Russian and Kazakh' do
      ['Спасибо, записала вас.', 'Вы записаны.', 'Запись создана.', 'Жаздым.', 'Жазылдыңыз.', 'Тіркелдіңіз.'].each do |draft|
        expect(completed(draft)).not_to be_empty, draft
      end
      ['Отменила запись.', 'Запись отменена.', 'Тоқтаттым.', 'Перенесла запись.', 'Ауыстырдым.'].each do |draft|
        expect(completed(draft)).not_to be_empty, draft
      end
    end

    it 'requires a successful result or a pending approval card for the matching action' do
      failed = [{ tool_name: 'cancel_appointment', success: false }]
      succeeded = [{ tool_name: 'cancel_appointment', success: true }]
      card = [{ tool_name: 'create_appointment', status: 'pending' }]

      expect(completed('Я отменила запись.', records: failed)).to eq(['cancel'])
      expect(completed('Я отменила запись.', records: succeeded)).to eq([])
      expect(completed('Записала вас.', cards: card)).to eq([])
      expect(completed('Записала вас.', cards: [{ tool_name: 'create_appointment', status: 'rejected' }])).to eq(['book'])
      expect(completed('Запись создана.', records: [{ tool_name: 'create_task', success: true }])).to eq(['create_state'])
    end

    it 'does not flag questions, future promises or facts unrelated to appointments' do
      ['Записать вас?', 'Запишу после подтверждения.', 'Я записала ваш номер.'].each do |draft|
        expect(completed(draft)).to eq([]), draft
      end
    end
  end
end
