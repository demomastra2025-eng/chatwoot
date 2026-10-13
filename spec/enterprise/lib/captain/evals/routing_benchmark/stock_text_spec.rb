# frozen_string_literal: true

require 'rails_helper'
require 'tmpdir'

RSpec.describe Captain::Evals::RoutingBenchmark::StockText do
  after { described_class.reset! }

  describe '.found' do
    it 'finds the sentences of the owner\'s list in Russian and in Kazakh' do
      expect(described_class.found('Хорошо. По этому вопросу вам ответит сотрудник клиники. Действие выполнено.'))
        .to eq(['По этому вопросу вам ответит сотрудник клиники.', 'Действие выполнено.'])
      expect(described_class.found('Сұрау тоқтатылды. Әрекет орындалды.')).to eq(['Сұрау тоқтатылды.', 'Әрекет орындалды.'])
      expect(described_class.found('Запрос отменён.')).to eq(['Запрос отменён.'])
    end

    it 'finds the fixed fallback sentence whole, and the opening of it when the rest is cut' do
      expect(described_class.found('Запрос обработан. Если нужны подробности, уточните, пожалуйста, вопрос.'))
        .to eq(['Запрос обработан. Если нужны подробности, уточните, пожалуйста, вопрос.'])
      expect(described_class.found('Запрос обработан.')).to eq(['Запрос обработан.'])
    end

    it 'finds a sentence with an interpolation, whatever fills the gap' do
      expect(described_class.found('Часть обращения осталась без ответа, нужен ответ сотрудника: запись на среду.'))
        .to eq(['Часть обращения осталась без ответа, нужен ответ сотрудника: запись на среду.'])
    end

    it 'tolerates other white space between the words and another case' do
      expect(described_class.found("запрос\n  отменён.")).to eq(['запрос отменён.'])
    end

    it 'finds nothing in an ordinary reply, in nil and in an empty text' do
      expect(described_class.found('Запись отменена по вашей просьбе. Ждём вас снова!')).to be_empty
      expect(described_class.found(nil)).to be_empty
      expect(described_class.found('')).to be_empty
    end
  end

  describe '.strip' do
    it 'cuts the sentences out and keeps the rest of the reply' do
      expect(described_class.strip('Записала вас на пятницу. Запрос отменён. До встречи!')).to eq('Записала вас на пятницу. До встречи!')
      expect(described_class.strip('Действие выполнено.')).to eq('')
      expect(described_class.strip(nil)).to eq('')
    end
  end

  describe 'the locale files' do
    it 'are read, every locale found: a sentence the owner adds to a file is a stock sentence at once' do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, 'captain_coordination.ru.yml'), { 'ru' => { 'captain' => { 'coordination' => { 'brand_new' => 'Новая заглушка рантайма.' } } } }.to_yaml)
        stub_const("#{described_class}::LOCALE_GLOB", File.join(dir, 'captain_coordination.*.yml'))
        described_class.reset!

        expect(described_class.found('Ответ. Новая заглушка рантайма.')).to eq(['Новая заглушка рантайма.'])
        expect(described_class.found('Действие выполнено.')).to eq(['Действие выполнено.'])
      end
    end

    it 'agree with the checkout under test: its own coordination texts are all found' do
      sentences = Dir.glob(Rails.root.join(described_class::LOCALE_GLOB)).flat_map do |path|
        YAML.safe_load_file(path).values.flat_map { |locale| locale.dig('captain', 'coordination').to_h.values }
      end.reject { |text| text.include?('%{') }
      described_class.reset!

      expect(sentences).to be_present
      expect(sentences.reject { |text| described_class.found(text).any? }).to be_empty
    end
  end
end
