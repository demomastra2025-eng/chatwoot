# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::PatientLanguage::KazakhMarkers do
  def kazakh?(text) = described_class.kazakh?(text)

  # Suggestion eval 26.10: the decision model answered Russian, six times in six for the same input, for turns like these.
  describe 'a Kazakh text, with Russian words in it or after older Russian messages' do
    it 'is read by the Kazakh letters and words of a sentence that has a Russian loanword' do
      [
        'Маған жақсы гинеколог врач керек еді, кім қабылдайды',
        'Маған врач керек, қанша тұрады',
        'Дәрігер бүгін қабылдайды ма, УЗИ жасатқым келеді',
        'Анализ жауабы қашан дайын болады, ватсапқа жіберіңізші'
      ].each { |text| expect(kazakh?(text)).to be(true), text }
    end

    it 'is read over a turn of short messages that mix in Russian words, one message to a line' do
      expect(kazakh?("?\nЖақсы 21-не жазып қойыңыз\nБағасы қанша болады узи?\nБеременность жоқ")).to be(true)
      expect(kazakh?("Кешке 7-8 ге бола ма\nАборт жасатқым келген")).to be(true)
      expect(kazakh?("Ақпаратыңызға рақмет, осы айдың аяғына суббота күнге жазылсам дегем, себебі Темір ауданында тұрам\n" \
                     'Алия Аблаевна қабылдайма')).to be(true)
    end

    it 'is read in a very short text with the Kazakh letters' do
      ['Аборт жасатқым келеді', 'рақмет', 'Қанша тұрады?', 'жоқ, келе алмаймын'].each { |text| expect(kazakh?(text)).to be(true), text }
    end

    it 'is read when typed without the special letters, by words that are Kazakh whichever way they are written' do
      ['Ертен кешке канша болады', 'Кешке 7-8 ге бола ма', 'Рахмет, жок, керек емес'].each { |text| expect(kazakh?(text)).to be(true), text }
    end
  end

  describe 'a text that is left to the model' do
    it 'is a Russian text, also with a Kazakh name in it' do
      [
        'Здравствуйте, подскажите стоимость приёма ЛОРа', 'Запишите Әлия на 10:00', 'Запишите ребёнка к Ғалымжану в субботу',
        'Әлия Нұрлан', 'Әлия принимает?', 'Нас трое: Ғалым, Нұрсултан и Айгерим', 'Добрый день! Хочу записаться к Қайрату Серикову'
      ].each { |text| expect(kazakh?(text)).to be(false), text }
    end

    it 'is a Russian sentence with one Kazakh word, or one thanks in Kazakh' do
      [
        'Спасибо, рахмет', 'Хочу записаться на приём к врачу, қанша стоит', 'Подскажите цену, рахмет большое', 'Рақмет', 'Сәлеметсіз бе',
        'Спасибо большое, жақсы'
      ].each { |text| expect(kazakh?(text)).to be(false), text }
    end

    it 'is a text with no words: digits, an IIN, an emoji, abbreviations, or nothing' do
      ['900101300123', '👍', 'УЗИ и ЭКГ', 'ИИН 900101300123', '?', '', nil].each { |text| expect(kazakh?(text)).to be(false), text.inspect }
    end

    it 'is an English text' do
      expect(kazakh?('Hello, how much is a consultation?')).to be(false)
    end
  end

  describe '.count' do
    it 'does not count a name in the middle of a sentence or an abbreviation, and counts a capitalized opening word as weak' do
      expect(described_class.count('Әлия: Нұрлан УЗИ рақмет')).to eq(strong: 1, weak: 1, total: 2)
      expect(described_class.count('Маған врач керек')).to eq(strong: 0, weak: 2, total: 3)
    end

    it 'starts a sentence after a full stop, a question mark or a new line, with quotes and brackets in between' do
      expect(described_class.count("Да. Қайрат\n(Әлия) пришёл")).to eq(strong: 0, weak: 2, total: 4)
      expect(described_class.count('Да, Қайрат пришёл')).to eq(strong: 0, weak: 0, total: 2)
    end
  end
end
