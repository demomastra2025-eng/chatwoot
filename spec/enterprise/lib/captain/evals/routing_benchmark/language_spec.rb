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

  describe '.mismatch' do
    it 'names why a text is not in the expected language, and is nil when it is' do
      expect(described_class.mismatch(:ru, 'Здравствуйте, ждём вас в клинике в среду.')).to be_nil
      expect(described_class.mismatch('kk', 'Сіз терапевтке жазылдыңыз, күтеміз')).to be_nil
      expect(described_class.mismatch(:kk, 'Здравствуйте, мне нужно записаться к терапевту')).to eq('the reply reads as ru, expected kk')
      expect(described_class.mismatch(:ru, 'Сіз терапевтке жазылдыңыз, күтеміз')).to eq('the reply reads as kk, expected ru')
      expect(described_class.mismatch(:ru, 'Please choose a time')).to eq('the reply has no Cyrillic')
    end

    it 'checks Russian and Kazakh only: a reply expected in any other language has no mismatch' do
      expect(described_class.checked?('ru')).to be(true)
      expect(described_class.checked?(:kk)).to be(true)
      expect(described_class.checked?('en')).to be(false)
      expect(described_class.mismatch('en', 'Please choose a time for the visit.')).to be_nil
      expect(described_class.mismatch('tr', 'Здравствуйте, ждём вас в клинике в среду.')).to be_nil
    end

    it 'lets a short neutral text and a weakly marked one pass' do
      ['15:00', 'ok', '👍', 'Дана Нурланова', 'Терапевт Ли Анна, среда 14 октября в 9:00'].each do |text|
        expect(described_class.mismatch(:kk, text)).to be_nil, text
        expect(described_class.mismatch(:ru, text)).to be_nil, text
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
