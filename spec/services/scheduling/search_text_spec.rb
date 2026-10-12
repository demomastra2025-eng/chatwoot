require 'rails_helper'

RSpec.describe Scheduling::SearchText do
  def normalized(text)
    described_class.normalize(text, max_length: nil)
  end

  describe '.words' do
    it 'keeps every word: short words, prepositions, digits, roman numerals, one-letter codes and decimals' do
      expect(described_class.words('мрт с контрастом 3 тл')).to eq(%w[мрт с контрастом 3 тл])
      expect(described_class.words('гепатит ii')).to eq(%w[гепатит ii])
      expect(described_class.words('витамин d3')).to eq(%w[витамин d3])
      expect(described_class.words('мрт 1.5 тл')).to eq(['мрт', '1.5', 'тл'])
    end

    it 'reads a decimal comma as the same number as a decimal point' do
      expect(described_class.words('мрт 1,5 тл')).to eq(['мрт', '1.5', 'тл'])
    end

    it 'has no cap, unlike the retrieval tokens' do
      text = (1..20).map { |index| "слово#{index}" }.join(' ')

      expect(described_class.words(text).size).to eq(20)
      expect(described_class.tokens(text).size).to eq(described_class::MAX_TOKENS)
    end
  end

  describe '.same_words?' do
    def same?(left, right, **)
      described_class.same_words?(normalized(left), normalized(right), **)
    end

    it 'is true for the same words in any order, any case, and with ё as е' do
      expect(same?('УЗИ малого таза', 'малого таза УЗИ')).to be(true)
      expect(same?('Приём терапевта', 'прием ТЕРАПЕВТА')).to be(true)
    end

    it 'keeps the order of the words when a preposition, a number or a code takes part in the name' do
      expect(same?('МРТ с контрастом', 'МРТ контрастом с')).to be(false)
      expect(same?('МРТ без контраста с седацией', 'МРТ с контрастом без седации')).to be(false)
      expect(same?('Массаж 10 сеансов по 30 минут', 'Массаж 30 сеансов по 10 минут')).to be(false)
      expect(same?('Вакцинация от 1 до 6 лет', 'Вакцинация от 6 до 1 лет')).to be(false)
      expect(same?('Холтер 24 часа 3 канала', 'Холтер 3 часа 24 канала')).to be(false)
    end

    it 'keeps the order for roman numerals, one-letter codes and prepositions that follow one another' do
      expect(same?('Гепатит I B', 'Гепатит B I')).to be(false)
      expect(same?('Лечение зуба с анестезией без рентгена', 'Лечение зуба без анестезии с рентгеном')).to be(false)
      expect(same?('Приём врача для детей без родителей', 'Приём врача без детей для родителей')).to be(false)
    end

    it 'is true for the same words in the same order, whatever the case' do
      expect(same?('МРТ с контрастом', 'мрт С КОНТРАСТОМ')).to be(true)
      expect(same?('Массаж 10 сеансов по 30 минут', 'массаж 10 сеансов по 30 минут')).to be(true)
      expect(same?('МРТ 1.5 Тл', 'МРТ 1,5 Тл')).to be(true)
    end

    it 'does not merge medical word forms or words with the same stem into a confident name' do
      expect(same?('МРТ кисти', 'МРТ кисты')).to be(false)
      expect(same?('МРТ кисти', 'МРТ кисть')).to be(false)
      expect(same?('УЗИ почки', 'УЗИ почек')).to be(false)
      expect(same?('Биопсия лимфоузла', 'Биопсия лимфоузлов')).to be(false)
    end

    it 'keeps a meaning-bearing word beyond the eight retrieval tokens' do
      prefix = 'МРТ головного мозга сосудов шеи позвоночника суставов кисти'

      expect(same?("#{prefix} с контрастом", "#{prefix} без контраста")).to be(false)
      expect(same?("#{prefix} 3 Тл", "#{prefix} 1.5 Тл")).to be(false)
    end

    it 'keeps the free order for a name of content words only' do
      expect(same?('УЗИ малого таза', 'таза малого УЗИ')).to be(true)
      expect(same?('Приём детского невролога', 'невролога детского приём')).to be(true)
    end

    it 'orders a person name only when it holds a digit' do
      expect(same?('Мурад Асланов', 'Асланов Мурад', stemmed: false)).to be(true)
      expect(same?('Кабинет 2 этаж 3', 'Кабинет 3 этаж 2', stemmed: false)).to be(false)
      expect(same?('Кабинет 2 этаж 3', 'этаж 3 Кабинет 2', stemmed: false)).to be(false)
    end

    it 'is false when a short word, a preposition, a number or a one-letter code differs' do
      expect(same?('МРТ с контрастом', 'МРТ без контраста')).to be(false)
      expect(same?('Анализ крови при беременности', 'Анализ крови после беременности')).to be(false)
      expect(same?('МРТ 3 Тл', 'МРТ 1.5 Тл')).to be(false)
      expect(same?('Гепатит I', 'Гепатит II')).to be(false)
      expect(same?('Витамин D', 'Витамин D3')).to be(false)
      expect(same?('Витамин B12', 'Витамин B1')).to be(false)
    end

    it 'is false when one side only has an extra word' do
      expect(same?('ЭКГ', 'ЭКГ с нагрузкой')).to be(false)
      expect(same?('ЭКГ с нагрузкой', 'ЭКГ')).to be(false)
    end

    it 'can compare words exactly, so that two forms of a person name are two different names' do
      expect(same?('Асланов Мурад', 'Асланова Мурад', stemmed: false)).to be(false)
      expect(same?('Мурад Асланов', 'Асланов Мурад', stemmed: false)).to be(true)
      expect(same?('Петров', 'Петр')).to be(false)
    end

    it 'compares texts without any word as plain text' do
      expect(same?('½', '½')).to be(true)
      expect(same?('½', '¼')).to be(false)
    end
  end

  describe '.request_covered?' do
    def covered?(query, *texts)
      described_class.request_covered?(normalized(query), texts.map { |text| normalized(text) })
    end

    it 'is true when the text holds every word of the request, also as part of a longer name' do
      expect(covered?('УЗИ малого таза', 'УЗИ органов малого таза')).to be(true)
      expect(covered?('Мурад Асланов', 'Асланов Мурад Тестович')).to be(true)
      expect(covered?('ЭКГ', 'ЭКГ с нагрузкой')).to be(true)
    end

    it 'accepts any order of words that tie nothing to their neighbours' do
      expect(covered?('таза малого УЗИ', 'УЗИ органов малого таза')).to be(true)
    end

    it 'is false when a word of the request is missing, or only a form or a part of it stands in the text' do
      expect(covered?('УЗИ органов малого таза', 'УЗИ малого таза')).to be(false)
      expect(covered?('МРТ кисти', 'МРТ кисты')).to be(false)
      expect(covered?('Асланов', 'Асланова Мария')).to be(false)
      expect(covered?('Кабинет 2', 'Кабинет 12')).to be(false)
    end

    it 'is false when a qualifier, a number or a code of the request is missing' do
      expect(covered?('МРТ с контрастом', 'МРТ без контраста')).to be(false)
      expect(covered?('Анализ крови при беременности', 'Анализ крови после беременности')).to be(false)
      expect(covered?('Гепатит I', 'Гепатит II')).to be(false)
      expect(covered?('Витамин B1', 'Витамин B12')).to be(false)
      expect(covered?('УЗИ для детей', 'УЗИ детей')).to be(false)
    end

    it 'keeps the order of the words once a qualifier or a number takes part in the request' do
      expect(covered?('МРТ с контрастом без седации', 'МРТ без контраста с седацией')).to be(false)
      expect(covered?('Кабинет 2 этаж 3', 'Кабинет 3 этаж 2')).to be(false)
      expect(covered?('этаж 3 Кабинет 2', 'Кабинет 3 этаж 2')).to be(false)
      expect(covered?('МРТ с контрастом', 'МРТ головного мозга с контрастом')).to be(true)
      expect(covered?('МРТ 1,5 Тл', 'МРТ головы 1.5 Тл')).to be(true)
    end

    it 'is true when one of several texts covers the request, and false without a text' do
      expect(covered?('МРТ шеи', 'МРТ шейного отдела', 'МРТ шеи и плечевого пояса')).to be(true)
      expect(covered?('МРТ шеи')).to be(false)
    end

    it 'is false for a request without any word, however many texts hold its punctuation' do
      expect(covered?('-', 'Анти-HCV')).to be(false)
      expect(covered?('...', 'Иванов И.И.')).to be(false)
      expect(covered?('', 'abc')).to be(false)
    end

    it 'is false when the text negates a word of the request that the request does not negate' do
      expect(covered?('Анализ натощак', 'Анализ не натощак')).to be(false)
      expect(covered?('Анализ не натощак', 'Анализ натощак')).to be(false)
      expect(covered?('Ходжкинская лимфома', 'Не-Ходжкинская лимфома')).to be(false)
      expect(covered?('Приём ЭКГ', 'Приём без ЭКГ')).to be(false)
    end

    it 'keeps a negation the request repeats, and an extra negated word the request does not mention' do
      expect(covered?('Анализ не натощак', 'Анализ не натощак')).to be(true)
      expect(covered?('Консультация без очереди', 'Консультация без очереди онлайн')).to be(true)
      expect(covered?('МРТ', 'МРТ без контраста')).to be(true)
      expect(covered?('Анализ крови', 'Анализ крови не натощак')).to be(true)
    end

    it 'is false for a request with more different words than the search reads' do
      words = (1..9).map { |index| "слово#{index}" }

      expect(covered?(words.join(' '), words.join(' '))).to be(false)
      expect(covered?(words.first(8).join(' '), words.join(' '))).to be(true)
    end
  end

  describe '.truncated?' do
    it 'tells that a text is longer than the normalised length limit' do
      expect(described_class.truncated?('мрт кисти')).to be(false)
      expect(described_class.truncated?('слово ' * 100)).to be(true)
    end
  end
end
