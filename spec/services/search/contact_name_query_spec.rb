require 'spec_helper'
require 'active_support/core_ext/string/access'

# This matcher also runs outside Rails; these specs deliberately need no database.
module Search; end
require_relative '../../../app/services/search/query_text'
require_relative '../../../app/services/search/contact_name_query'

RSpec.describe Search::ContactNameQuery do
  def matches(query, *parts)
    described_class.new(query).matches?(parts)
  end

  it 'finds Almas and Алмас in both directions, case-insensitively and by partial name' do
    aggregate_failures do
      expect(matches('Алмас', 'Almas')).to be(true)
      expect(matches('ALMAS', 'Алмас')).to be(true)
      expect(matches('алм', 'Almas')).to be(true)
      expect(matches('alm', 'Алмас')).to be(true)
      expect(matches('Алmас', 'Almas')).to be(true)
      expect(matches('Alмas', 'Алмас')).to be(true)
    end
  end

  it 'matches all full-name tokens in any order across three fields, including mixed scripts' do
    expect(matches('Nurlanuly Алмас Orazov', 'Almas', 'Оразов', 'Нұрланұлы')).to be(true)
    expect(matches('Алмас Missing', 'Almas', 'Оразов', 'Нұрланұлы')).to be(false)
  end

  it 'supports common Russian digraphs and optional soft signs before ya/yu/yo' do
    {
      'Zhukov' => 'Жуков', 'Shchukin' => 'Щукин', 'Chaykovskiy' => 'Чайковский', 'Khasan' => 'Хасан',
      'Ilya' => 'Илья', 'Tatyana' => 'Татьяна', 'Yuliya' => 'Юлия', 'Yelena' => 'Елена'
    }.each do |latin, cyrillic|
      expect(matches(latin, cyrillic)).to be(true), latin
      expect(matches(cyrillic, latin)).to be(true), cyrillic
    end
  end

  it 'supports Kazakh spellings without collapsing distinct original Cyrillic letters' do
    aggregate_failures do
      expect(matches('Qanysh', 'Қаныш')).to be(true)
      expect(matches('Kanysh', 'Қаныш')).to be(true)
      expect(matches('Қаныш', 'Qanysh')).to be(true)
      expect(matches('Қаныш', 'Kanysh')).to be(true)
      expect(matches('Галым', 'Ғалым')).to be(false)
      expect(matches('Ғалым', 'Ghalym')).to be(true)
      expect(matches('Ғалым', 'Galym')).to be(true)
      expect(matches('Ainur', 'Айнұр')).to be(true)
      expect(matches('Tanir', 'Тәңір')).to be(false)
      expect(matches('Tangir', 'Тәңір')).to be(true)
    end
  end

  it 'keeps е/ё interchangeability and common Latin spellings' do
    aggregate_failures do
      expect(matches('Семен', 'Семён')).to be(true)
      expect(matches('Semen', 'Семён')).to be(true)
      expect(matches('Semyon', 'Семен')).to be(true)
      expect(matches('Семён', 'Semen')).to be(true)
      expect(matches('Семён', 'Semyon')).to be(true)
      expect(matches('Семен', 'Semyon')).to be(true)
      expect(matches('Алексей', 'Aleksey')).to be(true)
      expect(matches('Алексей', 'Aleksei')).to be(true)
    end
  end

  it 'treats SQL wildcards, backslashes and regexp syntax literally' do
    aggregate_failures do
      expect(matches('%', 'Almas')).to be(false)
      expect(matches('_', 'Almas')).to be(false)
      expect(matches('Almas.*', 'Алмас')).to be(false)
      expect(matches('Алмас|.*', 'Someone else')).to be(false)
      expect(matches('Almas (VIP) [1] %_\\', 'Алмас (VIP) [1] %_\\')).to be(true)
      expect(matches('A\\_B\\%', 'Caller A_B%Tester')).to be(false)
    end
  end

  it 'cleans pasted names and bounds input and word expansion' do
    aggregate_failures do
      expect(matches("\u200EАлмас\u00A0Оразов\u0000", 'Almas', 'Orazov')).to be(true)
      expect(described_class.new('a' * 500).text.length).to eq(Search::QueryText::MAX_LENGTH)
      expect(matches('a b c d e missing', 'a b c d e')).to be(false)
      expect(matches('', 'Almas')).to be(false)
      expect(matches('ьъ', 'Almas')).to be(false)
    end
  end

  it 'keeps a fixed spelling budget even for maximally ambiguous names' do
    query = described_class.new('Қғёй' * 50)
    expect(query.send(:literals, query.text).size).to be <= described_class::MAX_LATIN_VARIANTS + 1
    expect(query.send(:regexps, 'y' * 200).size).to eq(1)
    expect(query.send(:regexps, 'y' * 200).first.length).to be <= 10 * Search::QueryText::MAX_LENGTH
  end
end
