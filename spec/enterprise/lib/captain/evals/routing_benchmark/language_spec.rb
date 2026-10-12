# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::Evals::RoutingBenchmark::Language do
  describe '.detect' do
    {
      'Сәлеметсіз бе! Терапевтке жазылғым келеді, алғаш рет барамын' => :kk,
      'Добрый день! жұмадағы УЗИ щитовидкины басқа күнге ауыстыруға бола ма?' => :kk,
      'Сіз терапевтке жазылдыңыз, күтеміз' => :kk,
      'Здравствуйте, мне нужно записаться к терапевту' => :ru,
      'Вы записаны к терапевту на среду в 9:00' => :ru
    }.each do |text, language|
      it "reads #{text.inspect} as #{language}" do
        expect(described_class.detect(text)).to eq(language)
      end
    end

    [
      'ок', 'Дана Нурланова', 'завтра в 10:00', '+7 701 123 45 67', '',
      # Kazakh names in a Russian sentence and a Russian service name in a Kazakh one are not enough
      'Әсел Нұрланова, завтра в 10',
      'Терапевт Ли Анна, среда 14 октября в 9:00',
      'Hello, I need a doctor'
    ].each do |text|
      it "is unsure about #{text.inspect}" do
        expect(described_class.detect(text)).to eq(:unknown)
      end
    end
  end

  describe '.script' do
    it 'tells Cyrillic, Latin and neutral text apart' do
      expect(described_class.script('Қайырлы күн')).to eq(:cyrillic)
      expect(described_class.script('Hello there')).to eq(:latin)
      expect(described_class.script('ok')).to eq(:neutral)
      expect(described_class.script('10:00')).to eq(:neutral)
      expect(described_class.script(nil)).to eq(:neutral)
    end
  end
end
