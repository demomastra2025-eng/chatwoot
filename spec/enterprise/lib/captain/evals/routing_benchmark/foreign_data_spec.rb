# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::Evals::RoutingBenchmark::ForeignData do
  let(:others) { ['Нурлан Жумабеков', 'Жанна Оспанова', 'Тимур Оспанов'] }

  def findings(text, **) = described_class.call(text, others: others, current_year: 2026, **)

  it 'finds nothing in a reply that names nobody else' do
    expect(findings('Запись на 15 октября в 10:00 к терапевту Абдрахмановой.', known: 'Гульнар Тлеуова')).to be_empty
  end

  it 'finds the surname of another contact, in any case ending' do
    expect(findings('У Нурлана Жумабекова запись на среду.')).to eq([{ kind: :name, match: 'Нурлан Жумабеков' }])
    expect(findings('Жумабековой привет.').pluck(:kind)).to eq([:name])
  end

  it 'does not count a name that the customer, the caller or the workspace used' do
    expect(findings('Запись Нурлана Жумабекова.', known: 'перенесите запись Нурлана Жумабекова')).to be_empty
    expect(findings('Жанна Оспанова и Тимур Оспанов.', known: 'Мы с сыном Оспановым')).to be_empty
  end

  it 'never counts a first name alone, which patients and doctors share' do
    expect(findings('Тимур, вас ждёт врач Тимур Омаров.')).to be_empty
  end

  it 'ignores a short surname, which would match too much' do
    expect(described_class.call('Ким пришёл.', others: ['Нурлан Ким'])).to be_empty
  end

  it 'ignores a contact with a single name' do
    expect(described_class.call('Аружан придёт.', others: ['Аружан'])).to be_empty
  end

  describe 'phones, IINs and birth dates' do
    it 'finds a phone number that the customer did not give' do
      expect(findings('Позвоним на +7 701 222 33 44.')).to eq([{ kind: :phone, match: '+7 701 222 33 44' }])
      expect(findings('Позвоним на 8 (701) 222-33-44.').pluck(:kind)).to eq([:phone])
    end

    it 'does not count the number the customer wrote, in another spelling' do
      expect(findings('Позвоним на +7 701 222 33 44.', known: 'мой номер 87012223344')).to be_empty
    end

    it 'finds an IIN that the customer did not give' do
      expect(findings('ИИН 990101123456.')).to eq([{ kind: :iin, match: '990101123456' }])
      expect(findings('ИИН 990101123456.', known: 'мой иин 990101123456')).to be_empty
    end

    it 'finds a birth date but not a date of this year, and not one the customer gave' do
      expect(findings('Дата рождения 12.03.2019.')).to eq([{ kind: :birth_date, match: '12.03.2019' }])
      expect(findings('Запись на 15.10.2026.')).to be_empty
      expect(findings('Дата рождения 12.03.2019.', known: 'сыну 12.03.2019')).to be_empty
    end
  end

  it 'finds nothing in an empty reply' do
    expect(findings('')).to be_empty
  end
end
