# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::Evals::RoutingBenchmark::ReplyFacts do
  describe '.times' do
    it 'reads clock times, hours and the Kazakh hour' do
      expect(described_class.times('Записала на 9:30, потом в 10 часов, затем в 14 ч.')).to contain_exactly([9, 30], [10, 0], [14, 0])
      expect(described_class.times('Сағат 12-де, ал 15:45-те келіңіз.')).to contain_exactly([12, 0], [15, 45])
    end

    it 'does not read a date, a price or a duration as a time' do
      expect(described_class.times('15.10.2026, 7 000 ₸, 1.5 часа, 30 минут')).to be_empty
    end

    it 'reads each time once' do
      expect(described_class.times('с 10:00 до 10:30 и снова 10:00')).to contain_exactly([10, 0], [10, 30])
    end
  end

  describe '.dates' do
    it 'reads a day and a month in Russian, in Kazakh and in numbers' do
      expect(described_class.dates('15 октября, 3 мая, 1 января')).to contain_exactly([15, 10], [3, 5], [1, 1])
      expect(described_class.dates('15 қазанда, 20 тамыз, 1 желтоқсан')).to contain_exactly([15, 10], [20, 8], [1, 12])
      expect(described_class.dates('15.10 и 3.05.2026')).to contain_exactly([15, 10], [3, 5])
      expect(described_class.dates('03.05.2026, 5.10')).to contain_exactly([3, 5], [5, 10])
    end

    it 'does not read a decimal, a price or a number followed by another word as a date' do
      expect(described_class.dates('1.5 часа, 7 000 ₸, 15 минут, 2 визита')).to be_empty
    end
  end

  describe '.surname' do
    it 'takes the first capitalised word after the specialty when another one follows' do
      expect(described_class.surname('Терапевт Абдрахманова Сауле')).to eq('абдрахманова')
      expect(described_class.surname('ЛОР Сергеев Павел')).to eq('сергеев')
      expect(described_class.surname('Кабинет УЗИ (врач Бекова Дана)')).to eq('бекова')
    end

    it 'takes nothing when the name could be a first name that patients share' do
      expect(described_class.surname('Гинеколог Ким Елена')).to be_nil
      expect(described_class.surname('Процедурный кабинет (забор анализов)')).to be_nil
      expect(described_class.surname('Врач Иванов')).to be_nil
    end
  end

  describe '.names_surname?' do
    it 'finds the surname in any case ending' do
      expect(described_class.names_surname?('Записала вас к Абдрахмановой.', 'абдрахманова')).to be(true)
      expect(described_class.names_surname?('Омарову сообщили.', 'омаров')).to be(true)
    end

    it 'does not find another name' do
      expect(described_class.names_surname?('Записала к Сергееву.', 'омаров')).to be(false)
    end
  end
end
