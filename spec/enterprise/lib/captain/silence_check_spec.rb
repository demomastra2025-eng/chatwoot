# frozen_string_literal: true

require 'rails_helper'

# The review of quality-fixes-1 (M1, H2): a silence about a short answer swallowed an accepted offer («Да, подходит» to a time that staff
# offered) and a confirmation of a visit that nobody agreed. The eval of 27.10 after it: a bare thanks, ok or «буду» after a voice note of
# staff, and after any message of the clinic that the history stamped with its send time, was sent to staff (8 of 10 wrong handoffs).
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

    it 'is closed by a bare thanks, ok or confirmation as any other message of the clinic is, whether a visit exists or not' do
      ['Спасибо', 'Ок', 'Рахмет', 'Ок, спасибо', 'Да'].each do |text|
        expect(reason(text, voice, visit)).to be_nil, text
        expect(reason(text, "[Sat 24.10 09:50] #{voice}", visit)).to be_nil, text
        expect(reason(text, voice, none)).to be_nil, text
      end
      ['Спасибо, буду', 'Рахмет, келемін'].each do |text|
        expect(reason(text, "[Sat 24.10 09:50] #{voice}", visit)).to be_nil, text
        expect(reason(text, "[Sat 24.10 09:50] #{voice}", none)).to eq(:no_agreed_visit), text
      end
    end

    it 'has no check of its own: the placeholder offers no time, and the reasons are the two of the words and the facts' do
      expect(described_class::REASONS).to eq(%i[no_agreed_visit offered_time])
      expect(described_class).not_to respond_to(:staff_voice_note?)
    end
  end

  # The history writes the send time in front of every message of the clinic («[Sat 24.10 09:50] ...»): it is a date and a clock time, but
  # no time the clinic offered. The eval of 27.10 read it as one for every ok and «буду», and sent those to staff.
  describe 'the send time that the history writes in front of the message of the clinic' do
    it 'is no time the clinic offered: an ok or «буду» to a reminder of the visit the contact has is a courtesy' do
      stamped = "[Sat 24.10 09:50] #{reminder}"

      ['Ок', 'Хорошо', 'Да', 'Спасибо, буду', 'Хорошо, придём'].each do |text|
        expect(reason(text, stamped, visit)).to be_nil, text
      end
    end

    it 'leaves a message of the clinic without a time or a date offering nothing, whatever time it was sent at' do
      expect(reason('Ок', '[Sat 24.10 09:50] УЗИ почек стоит 8000 тенге.', none)).to be_nil
      expect(reason('Хорошо', '[Sat 24.10 09:50] Ждём ваш ответ', none)).to be_nil
    end

    it 'still reads the time the clinic offers in the words of the message' do
      stamped_offer = "[Sat 24.10 09:50] #{offer}"

      expect(reason('Да, подходит', stamped_offer, visit)).to eq(:offered_time)
      expect(reason('Ок', '[Sat 24.10 09:50] Ждём вас завтра.', none)).to eq(:offered_time)
      expect(reason('Ок', '[Sat 24.10 09:50] Ждём вас завтра.', visit)).to be_nil
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
