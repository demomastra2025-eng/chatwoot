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
      'оператор керек',
      # wordings of the real staff_escalation fixtures and the examples of the class comment
      'менеджер керек маған',
      'с человеком хочу',
      'Мне нужен администратор',
      'Дайте администратора',
      'Оператормен байланыстырыңыз',
      'Администратор керек',
      # the complaints of the v2 fixtures: the management is to look into it and to get in touch
      'хочу чтобы руководство разобралось и мне перезвонили',
      'хочу чтобы руководство разобралось',
      'басшылық хабарлассын, қайталанбасын',
      'басшылық білсін, маған хабарласыңыздар'
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
      'сәлеметсіз бе, терапевтке жазылғым келеді',
      # a wish verb needs its target next to it, and "для" makes the person the beneficiary
      'нужна справка для администратора',
      'можно записать человека на завтра?',
      'хочу записаться к администратору клиники на пятницу',
      'әкімші үшін керек',
      # a third person who will call, or has called, is no request
      'мне вчера перезвонил администратор',
      'басшылық хабарласады'
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
