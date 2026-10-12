# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::Evals::RoutingBenchmark::HandoffClaims do
  def kinds(text) = described_class.kinds(text)

  describe 'claims that staff got the request' do
    {
      'Передала вашу просьбу администратору.' => :handoff_staff,
      'Передаю ваш вопрос сотруднику.' => :handoff_staff,
      'Я направила запрос менеджеру клиники.' => :handoff_staff,
      'Жалоба передана руководству.' => :handoff_staff,
      'Вопрос об оплате передан бухгалтерии.' => :handoff_staff,
      'Бухгалтеру передала.' => :handoff_staff,
      'Сообщила на ресепшен.' => :handoff_staff,
      'Сұрағыңызды әкімшіге жеткіздім.' => :handoff_staff,
      'Өтінішті қызметкерге жібердім.' => :handoff_staff,
      'С вами свяжутся по заявке.' => :handoff_staff,
      'Администратор свяжется с вами сегодня.' => :handoff_staff,
      'Вам перезвонят в течение часа.' => :handoff_staff,
      'Сізбен менеджер байланысады.' => :handoff_staff,
      # A question handed over with no addressee, a callback of one person, a wait for a call, a doctor as the addressee
      'Ваш вопрос передан, ожидайте ответа.' => :handoff_staff,
      'Ваша заявка передана.' => :handoff_staff,
      'Администратор перезвонит вам в течение часа.' => :handoff_staff,
      'Менеджер ответит вам сегодня.' => :handoff_staff,
      'Ожидайте звонка администратора.' => :handoff_staff,
      'Передала ваш вопрос врачу.' => :handoff_staff,
      'Сообщила коллегам.' => :handoff_staff,
      'Сұрағыңыз жеткізілді.' => :handoff_staff
    }.each do |text, kind|
      it "reads #{text.inspect}" do
        expect(kinds(text)).to eq(Array(kind))
      end
    end
  end

  describe 'claims that a "специалист" got the request' do
    [
      'Передала ваш вопрос специалисту — он уточнит.',
      'Запросы переданы специалисту.',
      'Передаю запрос на отмену записи специалисту.',
      'Сұрағыңызды маманға жолдадым.',
      'Өтінішіңізді маманға жібердім.'
    ].each do |text|
      it "reads #{text.inspect} apart from staff" do
        expect(kinds(text)).to eq([:handoff_ambiguous])
      end
    end

    it 'prefers the staff claim when the sentence names both' do
      expect(kinds('Передала администратору и специалисту.')).to eq([:handoff_staff])
    end
  end

  describe 'sentences that are not claims' do
    [
      'Запрос на перенос записи передан на обработку; запись пока не подтверждена.',
      'Могу передать вопрос администратору.',
      'Передать вас администратору?',
      'Передам вопрос администратору, если нужно.',
      'Администратор свяжется с вами?',
      'Если администратор свяжется с вами, сообщите ему номер.',
      'Я не передавала администратору.',
      'Не передала администратору, потому что вы не просили.',
      'Передала бы администратору, но он занят.',
      'Передайте сотруднику ИИН плательщика.',
      'Справку об оплате готовит бухгалтерия за 1 рабочий день.',
      'Запрос на оформление медосмотра для 15 сотрудников принят.',
      'Сотрудник лаборатории проверит статус и ответит в течение рабочего дня.',
      'Күтеміз.',
      # a doctor the patient is referred to, a doctor who answers at the visit, a wait with nobody named
      'Направила вас к врачу.',
      'Направляю вас к врачу-кардиологу.',
      'Врач ответит на ваши вопросы на приёме.',
      'Ожидайте ответа.',
      'Ваша заявка передана на обработку.',
      'Администратор перезвонит вам, если понадобится?'
    ].each do |text|
      it "finds nothing in #{text.inspect}" do
        expect(kinds(text)).to be_empty
      end
    end
  end

  it 'reads every sentence on its own and keeps the sentence of each claim' do
    claims = described_class.claims('Спасибо за обращение. Передала ваш вопрос специалисту. С вами свяжутся.')

    expect(claims).to eq([[:handoff_ambiguous, 'Передала ваш вопрос специалисту.'], [:handoff_staff, 'С вами свяжутся.']])
  end
end
