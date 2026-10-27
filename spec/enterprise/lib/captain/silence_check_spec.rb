# frozen_string_literal: true

require 'rails_helper'

# The review of quality-fixes-1 (M1, H2): a silence about a short answer swallowed an accepted offer («Да, подходит» to a time that staff
# offered), an answer to a voice note of staff whose words nobody knows, and a confirmation of a visit that nobody agreed.
RSpec.describe Captain::SilenceCheck do
  let(:visit) { Captain::Runtime::AgreedVisit.new(times: ['10:00']) }
  let(:none) { Captain::Runtime::AgreedVisit::NONE }
  let(:pending_card) { Captain::Runtime::AgreedVisit.new(pending: true) }
  let(:reminder) { 'Напоминаем: завтра в 10:00 у вас приём. Ждём вас.' }
  let(:offer) { 'Есть окно завтра в 14:00.' }

  def reason(text, last_clinic, agreed)
    described_class.unsafe_reason(text: text, last_clinic: last_clinic, visit: agreed)
  end

  describe 'a clinic voice note whose words are unknown' do
    let(:voice) { Captain::ReplySuggestion::HistoryBuilder::STAFF_VOICE_NOTE }

    it 'is never closed by a courtesy, whatever the patient answers and whether a visit exists' do
      ['Спасибо', 'Ок', 'Спасибо, буду', 'Рахмет, келемін', 'Да'].each do |text|
        expect(reason(text, voice, visit)).to eq(:unknown_voice_note), text
        expect(reason(text, voice, none)).to eq(:unknown_voice_note), text
      end
    end

    it 'names a voice note by the placeholder the history shows, even with the send stamp in front' do
      expect(reason('Спасибо', "[Sat 24.10 09:50] #{voice}", visit)).to eq(:unknown_voice_note)
      expect(described_class.staff_voice_note?('Здравствуйте')).to be(false)
      expect(described_class.staff_voice_note?(nil)).to be(false)
    end
  end

  describe 'a confirmation that the patient will come' do
    it 'needs a visit to confirm: an upcoming appointment or a booking card that waits for approval' do
      ['Спасибо, буду', 'Хорошо, придём', 'Рахмет, келемін', 'Принял, буду'].each do |text|
        expect(reason(text, reminder, none)).to eq(:no_agreed_visit), text
        expect(reason(text, reminder, visit)).to be_nil, text
        expect(reason(text, offer, pending_card)).to be_nil, text
      end
    end

    it 'is no confirmation when the dialog has no clinic message and no visit exists' do
      expect(reason('Спасибо, буду', nil, none)).to eq(:no_agreed_visit)
    end
  end

  describe 'an acceptance of a time that the clinic offered' do
    it 'is not a courtesy when the time is none of the visits the contact has' do
      ['Да, подходит', 'Ок', 'Хорошо', 'Жарайды', 'Иә', 'Давайте', 'Хорошо, буду'].each do |text|
        expect(reason(text, offer, visit)).to eq(:offered_time), text
        expect(reason(text, offer, none)).to eq(text.include?('буду') ? :no_agreed_visit : :offered_time), text
      end
    end

    it 'is a courtesy when the clinic message names the time of the visit the contact has (a reminder, a confirmation)' do
      ['Ок', 'Хорошо', 'Да', 'Спасибо, буду', 'Хорошо, придём'].each do |text|
        expect(reason(text, reminder, visit)).to be_nil, text
      end
    end

    it 'is not a courtesy when the clinic message names a day only and the contact has no visit' do
      expect(reason('Ок', 'Ждём вас завтра.', none)).to eq(:offered_time)
      expect(reason('Ок', 'Ждём вас завтра.', visit)).to be_nil
      expect(reason('Да', 'Принимаем с понедельника по пятницу', none)).to eq(:offered_time)
    end

    it 'lets a booking card that waits for approval cover the time it was prepared for' do
      expect(reason('Да, подходит', offer, pending_card)).to be_nil
    end

    it 'does not take a thanks for an acceptance, nor a message of the clinic without a time or a date' do
      expect(reason('Спасибо!', offer, none)).to be_nil
      expect(reason('Спасибо', 'УЗИ почек стоит 8000 тенге.', none)).to be_nil
      expect(reason('Ок', 'УЗИ почек стоит 8000 тенге.', none)).to be_nil
    end
  end

  describe '.offers_time?' do
    it 'reads a clock time, a date and a day of the week, in Russian and Kazakh' do
      ['Есть 14:00', 'В пятницу свободно', 'Ертең бос уақыт бар', '25 октября', 'на 24.10', 'в 10 часов'].each do |text|
        expect(described_class.offers_time?(text, none)).to be(true), text
      end
      expect(described_class.offers_time?('Здравствуйте! Чем помочь', none)).to be(false)
      expect(described_class.offers_time?(nil, none)).to be(false)
    end

    it 'compares clock times with the starts of the visits, ignoring the form of the clock' do
      expect(described_class.offers_time?('Приём в 9:30', Captain::Runtime::AgreedVisit.new(times: ['09:30']))).to be(false)
      expect(described_class.offers_time?('Приём в 9:30 или в 11:00', Captain::Runtime::AgreedVisit.new(times: ['09:30']))).to be(true)
    end
  end
end
