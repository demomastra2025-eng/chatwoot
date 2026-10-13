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

  describe 'claims that a result or a document is ready or sent' do
    [
      'Результат готов.', 'Результаты анализов готовы.', 'Ваша справка готова.', 'Справка отправлена вам на почту.',
      'Документы высланы.', 'Заключение направлено вам в WhatsApp.', 'Нәтиже дайын.', 'Нәтижеңіз дайын.', 'Анықтама жіберілді.',
      # a timing word does not excuse a statement about the patient's own result
      'Ваши результаты ОАК готовы в день сдачи после 16:00.', 'Результат уже готов, заберите после 16:00.', 'Ваш анализ ОАК готов.'
    ].each do |text|
      it "reads #{text.inspect} as a ready claim" do
        expect(kinds(text)).to eq([:handoff_ready])
      end
    end

    [
      'Результаты анализов готовы в течение 1-2 дней.', 'Справка будет готова через день.', 'Результат уже готов?', 'Результат пока не готов.',
      'Когда будет готов результат?', 'Справка готовится за 1 рабочий день.', 'Результат придёт на e-mail, как правило до 17:00.',
      # the turnarounds of the knowledge base ("ОАК — в день сдачи после 16:00; биохимия — на следующий рабочий день; УЗИ — сразу")
      'Результаты ОАК готовы в день сдачи после 16:00.', 'Результат биохимии готов на следующий рабочий день.',
      'Заключение УЗИ готово сразу после исследования.', 'Результат ЭКГ готов через 15 минут.', 'Результаты ТТГ готовы на следующий день.'
    ].each do |text|
      it "finds nothing in #{text.inspect}" do
        expect(kinds(text)).to be_empty
      end
    end

    # The replies of the g1 run (council_two_part_04 T1, council_three_part_02 T1 and T2): the agent says that it cannot tell. Every "ready" word is
    # read in its own clause, and the "қазір" of one clause does not turn the turnaround of the clause before it into a claim.
    [
      'ОАК әдетте тапсырған күні сағат 16:00-ден кейін дайын болады, бірақ нәтижесінің дайын екенін қазір растай алмаймын, ' \
      'қызметкер тексеріп, сізге жауап береді.',
      'Нәтиженің дайын екенін қазір тексере алмаймын.',
      'Ербол Тулегеновтің анализ нәтижесінің дайын екенін қазір тексере алмаймын.',
      'Нәтиже әлі дайын емес.'
    ].each do |text|
      it "finds nothing in the Kazakh negation #{text.inspect}" do
        expect(kinds(text)).to be_empty
      end
    end

    it 'keeps the clauses apart: the turnaround and the "now" of another clause are not mixed up' do
      expect(kinds('Результаты ОАК готовы в день сдачи после 16:00, а ваш анализ сейчас в работе.')).to be_empty
      expect(kinds('Результаты ОАК готовы в день сдачи после 16:00, ваш анализ готов.')).to eq([:handoff_ready])
    end

    it 'reads a request that is sent to staff as the hand-over of a request, and not as a document that was sent' do
      expect(kinds('Заявка на справку отправлена сотруднику.')).to eq([:handoff_staff])
      expect(kinds('Ваш запрос на справку передан администратору.')).to eq([:handoff_staff])
    end

    it 'is the claim of the sentence, next to a staff claim only when the sentence makes both' do
      expect(kinds('Результат готов, администратор свяжется с вами.')).to contain_exactly(:handoff_staff, :handoff_ready)
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

  describe '.promise_only?' do
    [
      'Администратор перезвонит вам в течение часа.', 'С вами свяжутся по заявке.', 'По анализу ОАК вам ответит сотрудник.',
      'Ожидайте звонка администратора.'
    ].each do |text|
      it "reads #{text.inspect} as a promise that hands nothing over" do
        expect(described_class.promise_only?(text)).to be(true)
      end
    end

    [
      'Передала вашу просьбу администратору.', 'Передала администратору, он перезвонит вам.', 'Здравствуйте.'
    ].each do |text|
      it "does not read #{text.inspect} as a bare promise" do
        expect(described_class.promise_only?(text)).to be(false)
      end
    end
  end

  it 'reads every sentence on its own and keeps the sentence of each claim' do
    claims = described_class.claims('Спасибо за обращение. Передала ваш вопрос специалисту. С вами свяжутся.')

    expect(claims).to eq([[:handoff_ambiguous, 'Передала ваш вопрос специалисту.'], [:handoff_staff, 'С вами свяжутся.']])
  end
end
