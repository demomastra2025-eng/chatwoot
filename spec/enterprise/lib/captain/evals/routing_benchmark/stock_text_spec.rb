# frozen_string_literal: true

require 'rails_helper'
require 'tmpdir'

RSpec.describe Captain::Evals::RoutingBenchmark::StockText do
  after { described_class.reset! }

  # Reads the locale sentences from a temporary file with the given `captain.coordination` values instead of the files of the checkout.
  def with_locale_sentences(coordination)
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'captain_coordination.ru.yml'), { 'ru' => { 'captain' => { 'coordination' => coordination } } }.to_yaml)
      stub_const("#{described_class}::LOCALE_GLOB", File.join(dir, 'captain_coordination.*.yml'))
      described_class.reset!
      yield
    end
  end

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
      expect(described_class.found('Хорошо. Запрос обработан. Если нужны подробности')).to eq(['Запрос обработан. Если нужны подробности'])
      expect(described_class.found('Сұрау өңделді. Толығырақ білу үшін')).to eq(['Сұрау өңделді. Толығырақ'])
    end

    it 'leaves an agent\'s own "запрос обработан" alone: only the fixed sentence is the fallback' do
      ['Ваш запрос обработан, менеджер свяжется с вами.', 'Запрос обработан.', 'Хорошо, ваш запрос обработан. Ждём вас.',
       'Мы пишем: Запрос обработан, спасибо.'].each do |text|
        expect(described_class.found(text)).to be_empty, text
        expect(described_class.strip(text)).to eq(text), text
      end
    end

    it 'returns the sentences in the order of the text' do
      expect(described_class.found('Действие выполнено. Запрос отменён. По этому вопросу вам ответит сотрудник клиники.'))
        .to eq(['Действие выполнено.', 'Запрос отменён.', 'По этому вопросу вам ответит сотрудник клиники.'])
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

    it 'takes a quoted name followed by a colon for an ordinary sentence, however the locale of the checkout puts it' do
      ['Стоимость «УЗИ щитовидной железы»: 6 000 ₸.', 'Стоимость: «Консультация терапевта, первичная»: 7 000 ₸.',
       'Записала вас на «Первичный приём терапевта»: вторник 20 октября, 11:00.', 'Остаётся открытым: запись на среду.'].each do |text|
        expect(described_class.found(text)).to be_empty, text
        expect(described_class.strip(text)).to eq(text), text
      end
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

    # rubocop:disable Style/FormatStringToken
    it 'skip a value that is mostly a placeholder: it is a template of a report, and as a pattern it would match an ordinary sentence' do
      coordination = { 'part_result' => '«%{request}»: %{result}', 'open_parts' => 'Остаётся открытым: %{parts}.',
                       'with_words' => 'Не удалось выполнить часть запроса %{parts}.', 'plain' => 'Ждите.' }

      with_locale_sentences(coordination) do
        expect(described_class.found('Стоимость «УЗИ»: 6 000 ₸. Остаётся открытым: запись.')).to be_empty
        expect(described_class.found('Не удалось выполнить часть запроса запись на среду.'))
          .to eq(['Не удалось выполнить часть запроса запись на среду.'])
        expect(described_class.found('Ждите.')).to eq(['Ждите.'])
      end
    end

    it 'cut a sentence that ends in a placeholder up to the end of the sentence, and not one character of it' do
      with_locale_sentences('trailing' => 'Ошибка при обработке запроса: %{details}') do
        text = 'Здравствуйте. Ошибка при обработке запроса: таймаут провайдера. До свидания.'

        expect(described_class.strip(text)).to eq('Здравствуйте. . До свидания.')
      end
    end
    # rubocop:enable Style/FormatStringToken

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
