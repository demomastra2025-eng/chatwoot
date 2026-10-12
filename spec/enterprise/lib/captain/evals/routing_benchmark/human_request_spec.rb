# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::Evals::RoutingBenchmark::HumanRequest do
  describe '.match?' do
    [
      'позовите оператора',
      'здрасте позовите оператора пж',
      'Соедините меня с администратором, пожалуйста',
      'хочу поговорить с человеком',
      'мне нужен живой человек',
      'можно живого человека?',
      'переключите на менеджера',
      'Не могу дозвониться, позовите оператора',
      'пусть руководство разберется',
      'хочу пожаловаться директору',
      'оператор шақырыңызшы',
      'ОСМС бойынша жолдамам бар, осы жөнінде қызметкермен сөйлескім келеді',
      'оператор керек'
    ].each do |text|
      it "reads #{text.inspect} as a request for a person" do
        expect(described_class.match?(text)).to be(true)
      end
    end

    [
      'Здравствуйте',
      'нужна справка для сотрудников',
      'запишите меня к терапевту',
      'когда менеджер свяжется?',
      'администратор клиники сказал приходить в пятницу',
      'не нужно звать оператора',
      'без оператора справлюсь',
      'сколько стоит приём? позвоните мне завтра',
      'сәлеметсіз бе, терапевтке жазылғым келеді'
    ].each do |text|
      it "does not read #{text.inspect} as a request for a person" do
        expect(described_class.match?(text)).to be(false)
      end
    end

    it 'reads each sentence on its own' do
      expect(described_class.match?('Спасибо, всё понятно. Позовите менеджера.')).to be(true)
      expect(described_class.match?('Позовите. Менеджер сказал нет.')).to be(false)
    end

    it 'is false for an empty text' do
      expect(described_class.match?(nil)).to be(false)
    end
  end
end
