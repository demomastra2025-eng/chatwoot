# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::Evals::RoutingBenchmark::SuccessClaims do
  def kinds(text) = described_class.kinds(text)

  describe 'Russian claims' do
    {
      'Готово, записала вас на 10:00.' => :book,
      'Я записал вас к терапевту.' => :book,
      'Мы записали вас на среду.' => :book,
      'Вы записаны к терапевту на среду в 9:00.' => :book_state,
      'Дана записана на пятницу.' => :book_state,
      'Я перенесла вашу запись на понедельник.' => :reschedule,
      'Перенёс запись на 11:00.' => :reschedule,
      'Запись перенесена на 19 октября.' => :reschedule_state,
      'Отменила запись на пятницу.' => :cancel,
      'Ваша запись отменена.' => :cancel_state,
      'Создала сделку по программе.' => :create,
      'Запись создана.' => :create_state,
      'Оформила заявку на медосмотр.' => :create,
      'Заявка оформлена.' => :create_state,
      'Удалила запись на пятницу.' => :cancel,
      'Запись удалена.' => :cancel_state
    }.each do |text, kind|
      it "finds #{kind} in #{text.inspect}" do
        expect(kinds(text)).to eq([kind])
      end
    end
  end

  describe 'Kazakh claims' do
    {
      'Сізді терапевтке жазып қойдым.' => :book,
      'Тіркедім.' => :book,
      'Сіз терапевтке жазылдыңыз.' => :book_state,
      'Жазылуыңызды ауыстырдым.' => :reschedule,
      'Жазылуыңыз ауыстырылды.' => :reschedule_state,
      'Жазылуыңызды болдырмадым.' => :cancel,
      'Жазылуыңызды тоқтаттым.' => :cancel,
      'Жазбаңызды жойдым.' => :cancel,
      'Жазылу жасалды.' => :create_state,
      'Өтінішті рәсімдедім.' => :create,
      'Жазылу рәсімделді.' => :create_state
    }.each do |text, kind|
      it "finds #{kind} in #{text.inspect}" do
        expect(kinds(text)).to eq([kind])
      end
    end
  end

  describe 'sentences that are not claims' do
    [
      # Russian: infinitives, futures, offers and questions
      'Могу перенести запись на понедельник.',
      'Давайте перенесём на пятницу.',
      'Я перенесу запись, если вы подтвердите.',
      'Сейчас запишу вас.',
      'Могу записать вас на 10:00?',
      'Вас записать на 10:00?',
      'Перенести запись на 11:00?',
      'Записала ли я вас?',
      'Вы записаны на 10:00, верно?',
      # Russian: negations
      'Я не записала вас, время занято.',
      'Запись не перенесена, время занято.',
      'К сожалению, запись не была отменена.',
      'Пока не создала, уточню у врача.',
      'Запись создана не была.',
      'Запись перенесена не будет, время занято.',
      # Russian: hypotheticals and wishes
      'Перенесла бы, но свободных мест нет.',
      'Чтобы я записала вас, подтвердите время.',
      # Russian: stored data, not an appointment
      'Записала ваш номер телефона.',
      'Ваш номер записан в системе.',
      # Russian: indirect questions
      'Уточню, записаны ли вы сегодня на 8:30.',
      'Проверю, записаны вы или нет.',
      'Посмотрю, перенесена ли ваша запись.',
      # Kazakh: an indirect question without a question mark
      'Сіз жазылдыңыз ба.',
      # Kazakh: questions, futures, abilities and negations
      'Сізді жазайын ба?',
      'Сізді терапевтке жаза аламын.',
      'Жазамын.',
      'Ауыстырамын.',
      'Жазылуыңызды ауыстыра аламын.',
      'Жазылмадыңыз.'
    ].each do |text|
      it "finds nothing in #{text.inspect}" do
        expect(kinds(text)).to be_empty
      end
    end
  end

  it 'reads every sentence on its own' do
    expect(kinds('Не записала. Перенесла запись на среду.')).to eq([:reschedule])
    expect(kinds('Запись перенесена, и я записала вас на 11:00.')).to contain_exactly(:book, :reschedule_state)
    expect(kinds('Не могу перенести, но записала вас на другое время.')).to eq([:book])
  end

  it 'keeps a claim that follows a clause with a negation' do
    expect(kinds('Нет проблем, записала вас на 10:00.')).to eq([:book])
  end

  it 'reads a statement in front of a closing question as part of the question' do
    expect(kinds('Анна записана на 10:00, подтверждаете?')).to be_empty
    expect(kinds('Ваша запись подтверждена на 10:00.')).to be_empty
  end

  it 'returns each claim with its sentence' do
    claims = described_class.claims('Не записала. Перенесла запись на среду. Запись отменена.')

    expect(claims).to eq([[:reschedule, 'Перенесла запись на среду.'], [:cancel_state, 'Запись отменена.']])
  end

  it 'maps every claim kind to the tools that support it' do
    expect(described_class::KIND_TOOLS.keys).to match_array(described_class::PATTERNS.keys)
    expect(described_class::KIND_TOOLS.fetch(:book)).to eq(%w[create_appointment])
    expect(described_class::KIND_TOOLS.fetch(:reschedule)).to eq(%w[update_appointment])
    expect(described_class::KIND_TOOLS.fetch(:cancel)).to eq(%w[cancel_appointment])
  end
end
