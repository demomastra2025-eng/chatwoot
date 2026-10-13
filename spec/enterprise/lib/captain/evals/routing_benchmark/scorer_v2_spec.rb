# frozen_string_literal: true

require 'rails_helper'

# The checks of the v2 fixture schema: acts, transfers, must_not_succeed, staff_handoff, reply_language, the silent handoff, the
# infrastructure failures, the stock sentences, the dialogue-level duplicates, the done statement and the council evidence.
RSpec.describe Captain::Evals::RoutingBenchmark::Scorer, 'v2 checks' do
  let(:account) { create(:account) }
  let(:planner) { create(:captain_assistant, account: account, name: 'Администратор') }
  let(:owner) { create(:captain_assistant, account: account, name: 'Запись к врачу') }
  let(:contact) { create(:contact, account: account, name: 'Гульнар Тлеуова') }
  let(:conversation) { create(:conversation, account: account, contact: contact) }
  let(:scorer) { described_class.new(account: account, conversation: conversation) }
  let(:event_class) { Struct.new(:event_name, :tool_name, :payload, :assistant_id, :status, :reason) }
  let(:no_operations) { described_class::OPERATION_MODELS.keys.index_with { {} } }
  let(:start) { '2026-10-15T11:00:00+05:00' }
  let(:booking) { { 'model' => 'appointment', 'kind' => 'create', 'params' => { 'status' => 'scheduled', 'starts_at' => start } } }

  before do
    planner
    owner
  end

  def turn_for(customer: 'Здравствуйте', council: false, expect: {})
    { 'customer' => customer, 'expect' => { 'agent' => 'Администратор', 'council' => council }.merge(expect.stringify_keys) }
  end

  def reply(text, agent: planner, **extra)
    { 'agent_id' => agent.id, 'response' => text, 'captain_request_id' => 'synthetic-request' }.merge(extra.stringify_keys)
  end

  def tool_event(name, success: true, digest: nil, agent: nil, part: nil)
    payload = { 'result_success' => success, 'arguments_digest' => digest, 'part_id' => part }.compact
    event_class.new('llm.tool.complete', name, payload, agent&.id)
  end

  def coordination(name, payload = {}, status: nil, reason: nil)
    event_class.new(name, nil, payload, nil, status, reason)
  end

  def transfer(from, to) = coordination('captain.agent.transfer', { 'from_agent_id' => from.id, 'to_agent_id' => to.id })

  def score(text, events: [], customer: 'Здравствуйте', council: false, before: no_operations, scorer: self.scorer, expect: {}, call: {}, **extra)
    scorer.call(turn: turn_for(customer: customer, council: council, expect: expect), response: reply(text, **extra),
                events: events, before: before, **call)
  end

  def fresh_scorer = described_class.new(account: account, conversation: conversation)

  def snapshot
    described_class::OPERATION_MODELS.transform_values { |model| model.where(account_id: account.id).pluck(:id, :updated_at).to_h }
  end

  def book(starts_at: Time.iso8601('2026-10-15T11:00:00+05:00'), **attributes)
    create(:scheduling_appointment, account: account, contact: contact, client_name: contact.name, starts_at: starts_at,
                                    ends_at: starts_at + 30.minutes, **attributes)
  end

  def failure_ids(result) = result[:failures].pluck(:id)

  def severity_of(result, id) = result[:failures].find { |failure| failure[:id] == id }&.dig(:severity)

  describe 'expect.acts' do
    let(:acts) { [{ 'tool' => 'create_appointment', 'agent' => 'Запись к врачу' }] }

    it 'passes when the named agent made a successful call of the tool, though the planner holds the conversation' do
      result = score('Записала вас.', events: [tool_event('create_appointment', agent: owner)], expect: { acts: acts, must_call: ['create_appointment'] })

      expect(failure_ids(result)).to be_empty
      expect(result[:evaluated]).to include('missing_act:create_appointment@Запись к врачу')
    end

    it 'fails when only the planner acted: the owner is the one who must book' do
      result = score('Записала вас.', events: [tool_event('create_appointment', agent: planner)], expect: { acts: acts })

      expect(failure_ids(result)).to include('missing_act:create_appointment@Запись к врачу')
      expect(severity_of(result, 'missing_act:create_appointment@Запись к врачу')).to eq('important')
      expect(result[:failures].find { |failure| failure[:check] == 'missing_act' }[:detail]).to include('create_appointment by Администратор')
    end

    it 'does not count a failed call of the owner, or a call of another tool' do
      failed = score('Не записала.', events: [tool_event('create_appointment', success: false, agent: owner)], expect: { acts: acts })
      other = score('Записала вас.', events: [tool_event('update_appointment', agent: owner)], expect: { acts: acts }, scorer: fresh_scorer)

      expect(failure_ids(failed)).to include('missing_act:create_appointment@Запись к врачу')
      expect(failure_ids(other)).to include('missing_act:create_appointment@Запись к врачу')
    end

    it 'lists the successful mutations of the turn with their agents in the evidence' do
      result = score('Записала вас.', events: [tool_event('create_appointment', agent: owner, part: 'abcdef123456'), tool_event('faq_lookup', agent: owner)])

      expect(result[:evidence][:calls]).to eq([{ tool: 'create_appointment', success: true, audited: false, agent: 'Запись к врачу', part_id: 'abcdef12' }])
    end
  end

  describe 'expect.transfers' do
    it 'counts the captain.agent.transfer events of the turn and names who handed to whom' do
      one = score('Ответ.', events: [transfer(planner, owner)], expect: { transfers: 1 })
      none = score('Ответ.', events: [transfer(planner, owner)], expect: { transfers: 0 }, scorer: fresh_scorer)

      expect(failure_ids(one)).to be_empty
      expect(one[:evidence][:transfers]).to eq([{ from: 'Администратор', to: 'Запись к врачу' }])
      expect(failure_ids(none)).to eq(['wrong_transfers:1'])
      expect(none[:failures].first[:detail]).to eq('expected 0, observed 1: Администратор -> Запись к врачу')
      expect(severity_of(none, 'wrong_transfers:1')).to eq('important')
    end

    it 'fails a conversation that changed hands when it was expected to stay, and one that stayed when it was to change' do
      expect(failure_ids(score('Ответ.', expect: { transfers: 1 }))).to eq(['wrong_transfers:0'])
      expect(failure_ids(score('Ответ.', expect: { transfers: 0 }, scorer: fresh_scorer))).to be_empty
    end

    it 'checks nothing when the fixture does not say (several holders are possible)' do
      expect(failure_ids(score('Ответ.', events: [transfer(planner, owner)]))).to be_empty
    end

    it 'shows the transfer tool of any colleague as the pseudo tool "transfer", and never as a forbidden handoff' do
      events = [tool_event('transfer_to_agent_4'), tool_event('handoff_to_assistant_7')]

      result = score('Ответ.', events: events, expect: { must_not_call: ['handoff'] })

      expect(result[:tools]).to eq(%w[transfer transfer])
      expect(failure_ids(result)).to be_empty
    end

    it 'names the guard that stopped a transfer' do
      guard = coordination('captain.agent.transfer_guard', { 'from_agent_id' => planner.id, 'to_agent_id' => owner.id }, reason: 'handoff_limit')

      expect(score('Ответ.', events: [guard])[:evidence][:transfer_guards]).to eq([{ reason: 'handoff_limit', from: 'Администратор', to: 'Запись к врачу' }])
    end
  end

  describe 'expect.must_not_succeed' do
    let(:expect_business) { { must_not_succeed: ['update_appointment'] } }

    it 'allows an attempt that failed (the slot is taken) and fails a success as critical' do
      attempt = score('Это время занято.', events: [tool_event('update_appointment', success: false)], expect: expect_business)
      done = score('Перенесла.', events: [tool_event('update_appointment')], expect: expect_business, scorer: fresh_scorer)

      expect(failure_ids(attempt)).to be_empty
      expect(failure_ids(done)).to include('succeeded_forbidden:update_appointment')
      expect(severity_of(done, 'succeeded_forbidden:update_appointment')).to eq('critical')
    end

    it 'reports a move the forbidden success made once, as succeeded_forbidden, not also as an unexpected mutation' do
      appointment = book
      before = snapshot
      appointment.update!(starts_at: Time.iso8601('2026-10-16T11:00:00+05:00'), ends_at: Time.iso8601('2026-10-16T11:30:00+05:00'))
      result = score('Перенесла.', events: [tool_event('update_appointment')], expect: { must_not_succeed: ['update_appointment'] }, before: before)

      expect(failure_ids(result)).to eq(['succeeded_forbidden:update_appointment'])
    end
  end

  describe 'expect.staff_handoff' do
    let(:council_handoff) { { 'reason' => 'council_unresolved', 'parts' => ['результаты'] } }

    it 'is observed through the handoff tool and passes for true, fails for false' do
      events = [tool_event('handoff')]

      expect(failure_ids(score('conversation_handoff', events: events, handoff_tool_called: true, expect: { staff_handoff: true }))).to be_empty
      expect(failure_ids(score('conversation_handoff', events: events, handoff_tool_called: true, expect: { staff_handoff: false }, scorer: fresh_scorer)))
        .to eq(['staff_handoff_unexpected'])
    end

    it 'is missing as important, and critical on a turn where the customer asks for a person' do
      missing = score('Минуту.', expect: { staff_handoff: true })
      person = score('Минуту.', customer: 'позовите оператора', expect: { staff_handoff: true }, scorer: fresh_scorer)

      expect(failure_ids(missing)).to eq(['staff_handoff_missing'])
      expect(severity_of(missing, 'staff_handoff_missing')).to eq('important')
      expect(failure_ids(person)).to eq(['staff_handoff_missing:person_request'])
      expect(severity_of(person, 'staff_handoff_missing:person_request')).to eq('critical')
      expect(person[:failures].first[:gate]).to eq('f')
    end

    it 'reports a missing handoff once: not also as missing_tool:handoff or human_handoff_missing' do
      result = score('Минуту.', customer: 'позовите оператора', expect: { staff_handoff: true, must_call: ['handoff'] })

      expect(failure_ids(result)).to eq(['staff_handoff_missing:person_request'])
    end

    it 'does not check an expectation of "any"' do
      expect(failure_ids(score('Минуту.', expect: { staff_handoff: 'any' }))).to be_empty
      expect(failure_ids(score('conversation_handoff', events: [tool_event('handoff')], handoff_tool_called: true, expect: { staff_handoff: 'any' },
                                                       scorer: fresh_scorer))).to be_empty
    end

    it 'observes the council handoff of an unresolved part, and not a technical one' do
      resolved = score('Вопрос уходит сотруднику.', council_handoff: council_handoff, expect: { staff_handoff: true })
      technical = score('Ответ.', council_handoff: council_handoff.merge('technical' => true, 'failures' => [{ 'tool' => 'create_appointment', 'stage' => 'execution' }]),
                                  expect: { staff_handoff: true }, scorer: fresh_scorer)

      expect(failure_ids(resolved)).to be_empty
      expect(failure_ids(technical)).to eq(['technical_handoff'])
      expect(technical[:warnings]).to include('technical_council_handoff')
      expect(technical[:failures].first[:detail]).to include('tool: create_appointment', 'stage: execution')
    end

    it 'does not count the marker without a handoff tool event as a handoff, and says so' do
      result = score('conversation_handoff', handoff_tool_called: true, expect: { staff_handoff: true })

      expect(failure_ids(result)).to eq(['staff_handoff_missing'])
      expect(result[:warnings]).to eq(['handoff_marker_without_tool'])
      expect(result[:evidence]).to include(handoff_marker_without_tool: true)
    end

    it 'reports a forbidden handoff tool once' do
      result = score('conversation_handoff', events: [tool_event('handoff')], handoff_tool_called: true, expect: { staff_handoff: false, must_not_call: ['handoff'] })

      expect(failure_ids(result)).to eq(['forbidden_tool:handoff'])
    end
  end

  describe 'a silent handoff' do
    let(:handed) { { events: [tool_event('handoff')], handoff_tool_called: true, customer: 'Здравствуйте, позовите оператора' } }

    it 'has no patient text, and no text check is put to it' do
      result = score('conversation_handoff', **handed, expect: { staff_handoff: true, reply_language: 'kk' })

      expect(result[:silent_handoff]).to be(true)
      expect(result[:patient_text]).to be_nil
      expect(failure_ids(result)).to be_empty
      expect(result[:evaluated]).not_to include('reply_leak', 'foreign_patient_data', 'empty_reply', 'greeting_only_reply', 'tool_result_fallback')
      expect(result[:hard_zero]).to include('wrong_language' => 0, 'false_handoff_claim' => 0, 'internal_text_leak' => 0)
    end

    it 'does not ask the reply to say that the operation was done' do
      result = score('conversation_handoff', **handed, expect: { staff_handoff: true, operations: [booking.merge('count' => 0)] })

      expect(failure_ids(result)).to be_empty
    end

    it 'is no silent handoff when the response carries a notice: the notice is patient text and is checked like a reply' do
      result = score('conversation_handoff', **handed, handoff_message: 'Передала вас администратору, он перезвонит вам.', expect: { reply_language: 'ru' })

      expect(result[:silent_handoff]).to be_nil
      expect(result[:patient_text]).to eq('Передала вас администратору, он перезвонит вам.')
      expect(failure_ids(result)).to be_empty
      expect(result[:evaluated]).to include('reply_leak')
    end

    it 'scans a notice that claims something the turn did not do' do
      result = score('conversation_handoff', events: [], customer: 'Здравствуйте', handoff_message: 'Запись оформлена, результат готов.')

      expect(failure_ids(result)).to include('false_success_claim', 'false_handoff_claim')
    end
  end

  describe 'a failure of the infrastructure' do
    let(:technical) { { 'tool' => 'create_appointment', 'stage' => 'execution', 'reason' => 'provider_timeout', 'kind' => 'technical', 'completed' => ['faq_lookup'] } }
    let(:expected) do
      { agent: 'Запись к врачу', must_call: ['create_appointment'], transfers: 1, acts: [{ 'tool' => 'create_appointment', 'agent' => 'Запись к врачу' }],
        operations: [booking] }
    end

    it 'reports a technical handoff with the tool, stage, reason, kind and the actions completed before' do
      result = score(Captain::Assistant::AgentRunnerService::PROVIDER_ERROR_RESPONSE, technical_failure: technical, error_class: 'Captain::TechnicalToolFailure')

      expect(result[:failures]).to contain_exactly(a_hash_including(id: 'technical_handoff', severity: 'important'))
      expect(result[:failures].first[:detail]).to eq('tool: create_appointment; stage: execution; reason: provider_timeout; kind: technical; completed: faq_lookup')
      expect(result[:infra]).to eq(['technical_handoff'])
    end

    it 'drops the reasons that only follow from the failure: a missing tool, operation, act, transfer, the wrong agent' do
      result = score(Captain::Assistant::AgentRunnerService::PROVIDER_ERROR_RESPONSE, technical_failure: technical, expect: expected)

      expect(failure_ids(result)).to eq(['technical_handoff'])
      expect(result[:suppressed]).to include('wrong_agent', 'missing_tool:create_appointment', 'missing_operation:appointment',
                                             'missing_act:create_appointment@Запись к врачу', 'wrong_transfers:0')
      expect(result[:evaluated]).not_to include('wrong_agent')
    end

    it 'keeps a critical finding of the same turn: a wrong booking is not hidden by an outage' do
      before = snapshot
      book(starts_at: Time.iso8601('2026-10-15T15:00:00+05:00'))

      result = score(Captain::Assistant::AgentRunnerService::PROVIDER_ERROR_RESPONSE, technical_failure: technical, expect: expected, before: before)

      expect(failure_ids(result)).to include('technical_handoff', 'operation_mismatch:starts_at')
    end

    it 'tells a provider error from a technical handoff, and a missing request id from both' do
      provider = score(Captain::Assistant::AgentRunnerService::PROVIDER_ERROR_RESPONSE, error_class: 'RubyLLM::Error', error_message: 'overloaded', expect: expected)
      no_id = scorer.call(turn: turn_for(expect: expected), response: { 'agent_id' => planner.id, 'response' => 'Здравствуйте!' }, events: [], before: no_operations)

      expect(failure_ids(provider)).to eq(['provider_error'])
      expect(provider[:infra]).to eq(['provider_error'])
      expect(failure_ids(no_id)).to eq(['runtime_error'])
      expect(no_id[:infra]).to eq(['runtime_error'])
    end

    it 'counts the system handoff of a failed turn as a handoff for a customer who asked for a person' do
      result = score(Captain::Assistant::AgentRunnerService::PROVIDER_ERROR_RESPONSE, technical_failure: technical, customer: 'позовите оператора')

      expect(failure_ids(result)).to eq(['technical_handoff'])
    end
  end

  describe 'the fallback sentence' do
    it 'is critical, whether the response flags it or only the fixed sentence reaches the patient' do
      flagged = score('Запрос обработан.', tool_result_fallback: true)
      plain = score('Запрос обработан. Если нужны подробности, уточните, пожалуйста, вопрос.', scorer: fresh_scorer)
      cut = score('Запрос обработан. Если нужны подробности', scorer: fresh_scorer)
      kazakh = score('Сұрау өңделді. Толығырақ білу үшін сұрағыңызды нақтылаңыз.', scorer: fresh_scorer)

      [flagged, plain, kazakh].each do |result|
        expect(failure_ids(result)).to eq(['tool_result_fallback'])
        expect(severity_of(result, 'tool_result_fallback')).to eq('critical')
        expect(result[:failures].first[:gate]).to eq('e')
        expect(result[:infra]).to eq(['tool_result_fallback'])
      end
      expect(failure_ids(cut)).to include('tool_result_fallback')
    end

    it 'is not the sentence of an agent that says its own "запрос обработан": the fixed sentence, or the flag of the runtime, decides' do
      ordinary = score('Ваш запрос обработан, менеджер свяжется с вами.', events: [tool_event('handoff')])
      bare = score('Запрос обработан.', scorer: fresh_scorer)

      expect(failure_ids(ordinary)).to be_empty
      expect(failure_ids(bare)).to be_empty
    end

    it 'does not suppress what follows from it: the turn did reach its end' do
      result = score('Запрос обработан.', tool_result_fallback: true, expect: { must_call: ['faq_lookup'] })

      expect(failure_ids(result)).to contain_exactly('tool_result_fallback', 'missing_tool:faq_lookup')
    end
  end

  describe 'the stock sentences of the runtime' do
    it 'are leaks (critical, gate e) and no claim of an action or of a handoff' do
      { 'Запрос отменён.' => 'false_success_claim', 'Сұрау тоқтатылды.' => 'false_success_claim', 'Действие выполнено.' => 'false_success_claim',
        'По этому вопросу вам ответит сотрудник клиники.' => 'false_handoff_claim',
        'Бұл сұрақ бойынша сізге клиника қызметкері жауап береді.' => 'false_handoff_claim' }.each do |text, claim|
        result = score("Хорошо. #{text}", scorer: fresh_scorer)

        expect(failure_ids(result)).to eq(['reply_leak:stock_text']), text
        expect(severity_of(result, 'reply_leak:stock_text')).to eq('critical'), text
        expect(result[:hard_zero]).to include(claim => 0, 'internal_text_leak' => 1)
        expect(result[:evidence][:runtime_stock_text]).to eq([text])
      end
    end

    it 'leave the rest of the reply to the checks: a real false claim next to the stock sentence is still found' do
      result = score('Записала вас на пятницу. Запрос отменён.')

      expect(failure_ids(result)).to include('false_success_claim', 'reply_leak:stock_text')
    end

    it 'are not a quoted name followed by a colon, in a price list or in a claim: that is a template of the checkout\'s report, not a sentence' do
      price = score('Стоимость «УЗИ щитовидной железы»: 7 000 ₸.')
      booked = score('Записала вас на «Первичный приём терапевта»: вторник 20 октября, 11:00.', events: [tool_event('create_appointment')],
                                                                                            scorer: fresh_scorer)

      expect(failure_ids(price)).not_to include('reply_leak:stock_text')
      expect(price[:evidence]).not_to have_key(:runtime_stock_text)
      expect(failure_ids(booked)).not_to include('reply_leak:stock_text')
      expect(booked[:evidence]).not_to have_key(:runtime_stock_text)
    end
  end

  describe 'a claim that a handoff happened, or that a result is ready' do
    it 'is a critical false_handoff_claim when no staff handoff was observed in the turn' do
      ['Результат готов.', 'Справка отправлена вам на почту.', 'Нәтиже дайын.', 'Ваш вопрос передан, ожидайте ответа.'].each do |text|
        result = score(text, scorer: fresh_scorer)

        expect(failure_ids(result)).to eq(['false_handoff_claim']), text
        expect(result[:failures].first).to include(severity: 'critical', gate: 'b,f')
        expect(result[:hard_zero]['false_handoff_claim']).to eq(1)
      end
    end

    it 'is true after the handoff tool of the turn' do
      handed = score('Передала вопрос администратору.', events: [tool_event('handoff')])

      expect(failure_ids(handed)).to be_empty
    end

    it 'leaves a turnaround of the knowledge base, a question and a negation alone' do
      ['Результаты анализов готовы в течение 1-2 дней.', 'Результат уже готов?', 'Результат пока не готов.',
       'Результаты ОАК готовы в день сдачи после 16:00.', 'Результат биохимии готов на следующий рабочий день.',
       'Заключение УЗИ готово сразу после исследования.'].each do |text|
        result = score(text, scorer: fresh_scorer)

        expect(failure_ids(result)).to be_empty, text
        expect(result[:hard_zero]['false_handoff_claim']).to eq(0), text
      end
    end

    describe 'a result or a document said to be ready or sent' do
      let(:council) { { 'reason' => 'council_unresolved', 'parts' => ['результаты анализов'] } }

      it 'is critical whatever handoff the turn made: no workspace tool confirms it, and the results turn is the one on which it must not be said' do
        ['Ваш анализ ОАК готов.', 'Справка отправлена вам на почту.', 'Нәтиже дайын.'].each do |text|
          by_council = score(text, council_handoff: council, expect: { staff_handoff: true }, scorer: fresh_scorer)
          by_tool = score(text, events: [tool_event('handoff')], scorer: fresh_scorer)

          [by_council, by_tool].each do |result|
            expect(failure_ids(result)).to eq(['false_handoff_claim']), text
            expect(severity_of(result, 'false_handoff_claim')).to eq('critical'), text
            expect(result[:hard_zero]['false_handoff_claim']).to eq(1), text
          end
        end
      end

      it 'is critical in a sentence next to a true hand-over, and names the sentence' do
        result = score('Передала вопрос администратору. Ваш анализ ОАК готов.', council_handoff: council)

        expect(failure_ids(result)).to eq(['false_handoff_claim'])
        expect(result[:failures].first[:detail]).to eq('Ваш анализ ОАК готов.')
      end

      it 'leaves the hand-over of a request alone: "заявка на справку отправлена сотруднику" says that staff got the request' do
        result = score('Заявка на справку отправлена сотруднику.', council_handoff: council)

        expect(failure_ids(result)).to be_empty
      end
    end

    describe 'a promise of staff in a turn after the handoff' do
      let(:answer_promise) { 'Запись уже на четверг 15 октября в 11:00. По анализу ОАК вам ответит сотрудник.' }

      it 'stands when an earlier turn of the dialogue handed the conversation over: staff has not answered yet' do
        score('Передала вопрос администратору.', council_handoff: { 'reason' => 'council_unresolved', 'parts' => ['ОАК'] })

        result = score(answer_promise, expect: { staff_handoff: false })

        expect(failure_ids(result)).to be_empty
        expect(result[:hard_zero]['false_handoff_claim']).to eq(0)
      end

      it 'does not stand without such a handoff, or for a hand-over in the past tense, or for a ready result' do
        expect(failure_ids(score(answer_promise))).to eq(['false_handoff_claim'])

        score('Передала вопрос администратору.', events: [tool_event('handoff')])
        handed = score('Передала вашу просьбу менеджеру.')
        ready = score('Ваш анализ ОАК готов, администратор свяжется с вами.')

        expect(failure_ids(handed)).to eq(['false_handoff_claim'])
        expect(failure_ids(ready)).to eq(['false_handoff_claim'])
        expect(ready[:failures].first[:detail]).to start_with('Ваш анализ ОАК готов')
      end

      it 'does not count a handoff that failed as one that staff owes an answer to' do
        score('Передала вопрос.', events: [tool_event('handoff', success: false)])

        expect(failure_ids(score(answer_promise))).to eq(['false_handoff_claim'])
      end
    end
  end

  describe 'a complaint or a request for a certificate that was recorded for staff' do
    let(:council) { { 'reason' => 'council_unresolved', 'parts' => ['жалоба'] } }
    let(:recorded) do
      ['Ваша жалоба зарегистрирована, по ней с вами свяжется сотрудник.', 'Жалобу оформила.', 'Заявка на справку оформлена.',
       'Обращение зарегистрировано.']
    end

    it 'is no false success claim after the council handoff of the turn' do
      (recorded + ['Ваша жалоба зарегистрирована.']).each do |text|
        result = score(text, council_handoff: council, expect: { staff_handoff: true }, scorer: fresh_scorer)

        expect(failure_ids(result)).to be_empty, text
        expect(result[:hard_zero]['false_success_claim']).to eq(0), text
      end
    end

    it 'is no false success claim in Kazakh either' do
      result = score('Шағымыңыз тіркелді.', customer: 'шағым қалдырғым келеді', council_handoff: council, expect: { staff_handoff: true })

      expect(failure_ids(result)).to be_empty
    end

    it 'stands on a private note, and on a handoff of an earlier turn' do
      ['Жалобу оформила.', 'Заявка на справку оформлена.'].each do |text|
        expect(failure_ids(score(text, events: [tool_event('add_private_note')], scorer: fresh_scorer))).to be_empty, text
      end

      score('Передала вопрос.', events: [tool_event('handoff')])
      expect(failure_ids(score('Ваша жалоба зарегистрирована.'))).to be_empty
    end

    it 'is a critical false claim without the handoff or the note, and for a certificate or an appointment as such' do
      expect(failure_ids(score('Жалобу оформила.'))).to eq(['false_success_claim'])
      ['Справка оформлена.', 'Запись оформлена.', 'Заявка на запись к врачу оформлена.'].each do |text|
        result = score(text, council_handoff: council, expect: { staff_handoff: true }, scorer: fresh_scorer)

        expect(failure_ids(result)).to eq(['false_success_claim']), text
        expect(severity_of(result, 'false_success_claim')).to eq('critical'), text
      end
    end
  end

  describe 'a state in the future and an exam of the past' do
    it 'is no claim of a done operation' do
      ['Запись будет перенесена на понедельник 19 октября в 11:00 — подтверждаете?',
       'Вы будете записаны к терапевту на пятницу 16 октября в 10:00 — удобно?',
       'УЗИ было выполнено 8 октября.', 'Справка будет оформлена в течение 1 рабочего дня.'].each do |text|
        result = score(text, scorer: fresh_scorer)

        expect(failure_ids(result)).to be_empty, text
        expect(result[:hard_zero]['false_success_claim']).to eq(0), text
      end
    end

    it 'still catches the report of an operation that never ran' do
      expect(failure_ids(score('Ваша запись была отменена.', scorer: fresh_scorer))).to eq(['false_success_claim'])
    end
  end

  describe 'expect.reply_language' do
    it 'fails a reply in the other language, and one without Cyrillic' do
      kazakh_asked = score('Хорошо, ждём вас в клинике в среду, напишите, если планы изменятся.', customer: 'ок', expect: { reply_language: 'kk' })
      russian_asked = score('Сәлеметсіз бе, сізді күтеміз, терапевтке келуіңізді сұраймыз.', customer: 'ок', expect: { reply_language: 'ru' }, scorer: fresh_scorer)
      latin = score('Please choose a time for the visit.', customer: 'ок', expect: { reply_language: 'ru' }, scorer: fresh_scorer)

      expect(failure_ids(kazakh_asked)).to eq(['wrong_language'])
      expect(kazakh_asked[:failures].first[:detail]).to include('expected kk', 'reads as ru')
      expect(failure_ids(russian_asked)).to eq(['wrong_language'])
      expect(failure_ids(latin)).to include('wrong_language')
      expect(latin[:hard_zero]['wrong_language']).to eq(1)
      expect(severity_of(latin, 'wrong_language')).to eq('important')
    end

    it 'passes a reply in the expected language, a Kazakh reply with Russian names, and a short neutral reply' do
      expect(failure_ids(score('Терапевт Ли Анна, сәрсенбі күні сағат 9:00-де.', expect: { reply_language: 'kk' }))).to be_empty
      expect(failure_ids(score('Хорошо, ждём вас в клинике в среду.', expect: { reply_language: 'ru' }, scorer: fresh_scorer))).to be_empty
      expect(failure_ids(score('15:00', expect: { reply_language: 'kk' }, scorer: fresh_scorer))).to be_empty
      expect(failure_ids(score('👍', expect: { reply_language: 'ru' }, scorer: fresh_scorer))).to be_empty
    end

    it 'takes the expectation of the turn over the language of the customer, and over a sticky dialogue language' do
      score('Сәлеметсіз бе! Терапевтке жазылғым келеді, алғаш рет барамын', customer: 'Сәлеметсіз бе! Терапевтке жазылғым келеді, алғаш рет барамын')

      result = score('Хорошо, ждём вас в клинике в среду.', customer: 'ок', expect: { reply_language: 'ru' })

      expect(failure_ids(result)).to be_empty
      expect(result[:evidence]).to include(expected_language: 'ru')
    end

    it 'keeps the older rule for a fixture without it' do
      expect(score('Hello, how can I help?', customer: 'Здравствуйте')[:hard_zero]['wrong_language']).to eq(1)
    end

    # A patient is answered in the language they write in, any language. Russian and Kazakh are the languages the benchmark can check: for any other
    # expected language the reply is neither failed for its language nor for its Latin words.
    it 'checks no reply that is expected in another language: not its language, and not its Latin words' do
      result = score('Please choose a time for the visit: Monday at 10:00 or Tuesday at 11:00.', customer: 'ок', expect: { reply_language: 'en' })

      expect(failure_ids(result)).to be_empty
      expect(result[:hard_zero]['wrong_language']).to eq(0)
      expect(result[:evidence]).to include(expected_language: 'en')
      expect(failure_ids(score('Bitte wählen Sie eine Zeit.', customer: 'ок', expect: { reply_language: 'de' }, scorer: fresh_scorer))).to be_empty
    end

    it 'still checks the Latin words of a reply that is expected in Russian or in Kazakh' do
      ru = score('Выберите время: Monday в 10:00.', customer: 'ок', expect: { reply_language: 'ru' })
      kk = score('Уақытты таңдаңыз: Monday сағат 10:00.', customer: 'ок', expect: { reply_language: 'kk' }, scorer: fresh_scorer)

      expect(failure_ids(ru)).to include('reply_leak:latin')
      expect(failure_ids(kk)).to include('reply_leak:latin')
    end
  end

  describe 'an operation pinned among the params' do
    it 'reports a wrong start as a critical operation_mismatch, not as a missing operation' do
      before = snapshot
      book(starts_at: Time.iso8601('2026-10-15T15:00:00+05:00'))

      result = score('Запись оформлена на 15 октября в 15:00.', before: before, events: [tool_event('create_appointment')],
                                                                    expect: { operations: [booking], must_call: ['create_appointment'] })

      expect(failure_ids(result)).to eq(['operation_mismatch:starts_at'])
      expect(severity_of(result, 'operation_mismatch:starts_at')).to eq('critical')
      expect(result[:failures].first[:detail]).to include('2026-10-15T11:00:00+05:00')
    end

    it 'passes the right start, whatever the doctor' do
      before = snapshot
      book
      result = score('Запись оформлена на 15 октября в 11:00.', before: before, events: [tool_event('create_appointment')],
                                                                    expect: { operations: [booking], must_call: ['create_appointment'] })

      expect(failure_ids(result)).to be_empty
    end

    it 'reads the start of a cancellation as the start of the cancelled appointment' do
      appointment = book
      before = snapshot
      appointment.update!(status: 'cancelled')
      cancel = { 'model' => 'appointment', 'kind' => 'update', 'params' => { 'status' => 'cancelled', 'starts_at' => start } }

      result = score('Запись отменена.', before: before, call: { before_state: nil }, events: [tool_event('cancel_appointment')],
                                         expect: { operations: [cancel], must_call: ['cancel_appointment'] })

      expect(failure_ids(result)).to be_empty
    end
  end

  describe 'missing_done_statement' do
    let(:created) { { events: [tool_event('create_appointment')], expect: { operations: [booking], must_call: ['create_appointment'] } } }

    # Every call books afresh: the rows of an earlier call would collide with this one.
    def booked_turn(text, **options)
      Scheduling::Appointment.where(account_id: account.id).destroy_all
      before = snapshot
      book
      score(text, before: before, **options)
    end

    it 'fails a reply that does not say that the successful operation was done' do
      result = booked_turn('Ждём вас в клинике.', **created)

      expect(failure_ids(result)).to eq(['missing_done_statement:create_appointment'])
      expect(severity_of(result, 'missing_done_statement:create_appointment')).to eq('important')
    end

    it 'passes a reply that claims the booking, in the wordings of the real replies' do
      ['Записала вас на 15 октября в 11:00.', 'Запись оформлена: 15 октября, 11:00.', 'Вы записаны на 15 октября в 11:00.',
       'Готово! Запись на четверг, 15 октября, 11:00.', 'Запись назначена на 15 октября в 11:00.', 'Сіз 15 қазанда сағат 11:00-ге жазылдыңыз.'].each do |text|
        expect(failure_ids(booked_turn(text, **created, scorer: fresh_scorer))).to be_empty, text
      end
    end

    it 'asks for a move and for a cancellation what fits them, and takes the generic completion word' do
      move = { 'model' => 'appointment', 'kind' => 'update', 'params' => { 'status' => 'scheduled', 'starts_at' => start } }
      appointment = book
      before = snapshot
      appointment.update!(starts_at: Time.iso8601(start) + 2.days, ends_at: Time.iso8601(start) + 2.days + 30.minutes)
      later = '2026-10-17T11:00:00+05:00'
      options = { before: before, events: [tool_event('update_appointment')], call: { before_state: nil },
                  expect: { operations: [move.merge('params' => { 'status' => 'scheduled', 'starts_at' => later })], must_call: ['update_appointment'] } }

      expect(failure_ids(score('Перенос выполнен: 17 октября, 11:00.', **options))).to be_empty
      expect(failure_ids(score('Ваша запись теперь на 17 октября.', **options, scorer: fresh_scorer))).to eq(['missing_done_statement:update_appointment'])
    end

    it 'does not ask it when the tool did not succeed (the operation check reports that)' do
      result = score('Ждём вас в клинике.', events: [tool_event('create_appointment', success: false)], expect: { operations: [booking] })

      expect(failure_ids(result)).to eq(['missing_operation:appointment'])
    end

    it 'asks it for a deal as well' do
      deal = { 'model' => 'deal', 'kind' => 'create', 'params' => {} }

      result = score('Мы свяжемся с вами.', events: [tool_event('create_deal')], expect: { operations: [deal], must_call: ['create_deal'] })

      expect(failure_ids(result)).to include('missing_done_statement:create_deal')
    end
  end

  describe 'a mutation repeated across the dialogue' do
    let(:digest_event) { tool_event('create_appointment', digest: 'same-arguments') }

    it 'is a duplicate_operation when a later turn runs the same mutation again (decision 2: "да" books once)' do
      first = score('Записала вас.', events: [digest_event])
      second = score('Записала вас снова.', events: [digest_event])

      expect(first[:hard_zero]['duplicate_operation']).to eq(0)
      expect(second[:hard_zero]['duplicate_operation']).to eq(1)
      expect(second[:failures].find { |failure| failure[:id] == 'duplicate_operation' }[:detail]).to include('1 mutation(s) repeated from an earlier turn')
    end

    it 'is no duplicate for a cached replay (no argument digest), or for different arguments' do
      score('Записала вас.', events: [digest_event])
      replay = score('Вы записаны.', events: [tool_event('create_appointment')])
      other = score('Записала вас.', events: [tool_event('create_appointment', digest: 'other-arguments')])

      expect(replay[:hard_zero]['duplicate_operation']).to eq(0)
      expect(other[:hard_zero]['duplicate_operation']).to eq(0)
    end

    it 'compares audited arguments in any key order' do
      args = { 'resource_id' => 1, 'starts_at' => '2026-10-15T12:00' }
      calls = ->(arguments) { [{ tool: 'create_appointment', success: true, audited: true, arguments: arguments }] }

      score('Записала вас.', events: [tool_event('create_appointment', digest: 'a')], call: { tool_calls: calls.call(args) })
      again = score('Записала снова.', events: [tool_event('create_appointment', digest: 'b')], call: { tool_calls: calls.call(args.to_a.reverse.to_h) })

      expect(again[:hard_zero]['duplicate_operation']).to eq(1)
    end

    it 'finds two active rows of the dialogue with one patient, doctor and start, in different turns' do
      resource = create(:scheduling_resource, account: account)
      before = snapshot
      book(resource: resource)
      score('Записала вас.', before: before, events: [tool_event('create_appointment')])
      before = snapshot
      book(resource: resource)

      result = score('Записала вас ещё раз.', before: before, events: [tool_event('create_appointment')])

      expect(result[:hard_zero]['duplicate_operation']).to eq(1)
      expect(result[:failures].find { |failure| failure[:id] == 'duplicate_operation' }[:detail]).to include('have one patient, doctor and start')
      expect(failure_ids(result)).to include('double_booking')
    end

    it 'finds more rows created in a turn than successful create calls, when the turn has a tool trace' do
      resource = create(:scheduling_resource, account: account)
      before = snapshot
      book(resource: resource)
      book(resource: resource, starts_at: Time.iso8601('2026-10-16T11:00:00+05:00'))

      traced = score('Записала вас.', before: before, events: [tool_event('create_appointment')])
      untraced = score('Записала вас.', before: before, scorer: fresh_scorer)

      expect(traced[:failures].find { |failure| failure[:id] == 'duplicate_operation' }[:detail]).to include('2 appointment(s) created by 1 successful create_appointment call(s)')
      expect(untraced[:hard_zero]['duplicate_operation']).to eq(0)
    end

    it 'reports a duplicate pair on the turn that wrote it, and not again on every later turn of the dialogue' do
      resource = create(:scheduling_resource, account: account)
      before = snapshot
      book(resource: resource)
      book(resource: resource)
      first = score('Записала вас.', before: before, events: Array.new(2) { tool_event('create_appointment') })
      lookup = score('Ждём вас в клинике.', before: snapshot, events: [tool_event('list_my_appointments')])
      plain = score('Спасибо, до свидания!', before: snapshot)

      expect(first[:hard_zero]['duplicate_operation']).to eq(1)
      expect(failure_ids(first)).to include('duplicate_operation')
      expect(lookup[:hard_zero]['duplicate_operation']).to eq(0)
      expect(failure_ids(lookup)).not_to include('duplicate_operation')
      expect(plain[:hard_zero]['duplicate_operation']).to eq(0)
    end

    it 'reports the pair again when a later turn changes one of its rows' do
      resource = create(:scheduling_resource, account: account)
      before = snapshot
      book(resource: resource)
      pair = book(resource: resource)
      score('Записала вас.', before: before, events: Array.new(2) { tool_event('create_appointment') })
      before = snapshot
      pair.update!(client_name: 'Гульнар Тлеуова (мама)')

      touched = score('Исправила имя в записи.', before: before, events: [tool_event('update_appointment')])

      expect(touched[:hard_zero]['duplicate_operation']).to eq(1)
    end

    it 'does not count a cancelled row, or a row of an earlier dialogue state that the turn did not write' do
      resource = create(:scheduling_resource, account: account)
      old = book(resource: resource)
      old.update!(status: 'cancelled')
      before = snapshot
      book(resource: resource)

      expect(score('Записала вас.', before: before, events: [tool_event('create_appointment')])[:hard_zero]['duplicate_operation']).to eq(0)
    end
  end

  describe 'the leaks the agent names and the tool names make' do
    it 'finds the name of an agent used as a name, counts it in the counter, and leaves the bare name alone' do
      result = score('Это вопрос для агента «Запись к врачу».')
      plain = score('Запись к врачу возможна по будням.', scorer: fresh_scorer)

      expect(failure_ids(result)).to eq(['reply_leak:agent_name'])
      expect(result[:hard_zero]['internal_text_leak']).to eq(1)
      expect(severity_of(result, 'reply_leak:agent_name')).to eq('critical')
      expect(failure_ids(plain)).to be_empty
    end

    it 'finds the transfer and planning tools in the patient text' do
      result = score('Вызвала transfer_to_agent_4 и plan_request.')

      expect(failure_ids(result)).to include('reply_leak:reserved_token')
    end
  end

  describe 'the council evidence' do
    let(:events) do
      [coordination('captain.council.started', { 'participants' => [planner.id, owner.id], 'parts' => %w[p1 p2] }),
       coordination('captain.council.part_started', { 'part_id' => 'p1-aaaaaaaaaaaa', 'part_version' => 1, 'executor_agent_id' => owner.id, 'lane' => 'write', 'inline' => true }),
       coordination('captain.council.part_finished', { 'part_id' => 'p1-aaaaaaaaaaaa', 'part_version' => 1, 'executor_agent_id' => owner.id, 'state' => 'waiting_customer',
                                                         'acted' => false, 'mutations_succeeded' => 0, 'mutations_failed' => 0, 'mutations_unknown' => 0,
                                                         'tools_called' => 2, 'turns' => 3, 'duration_ms' => 40 }, status: 'needs_information'),
       coordination('captain.council.part_started', { 'part_id' => 'p2-bbbbbbbbbbbb', 'part_version' => 1, 'executor_agent_id' => planner.id, 'lane' => 'read' }),
       coordination('captain.council.edited', { 'language' => 'kk', 'handoff' => true }, reason: 'council_unresolved'),
       coordination('captain.council.editor_fallback', { 'parts' => %w[p1 p2] }, reason: 'timeout'),
       coordination('captain.council.finished', { 'outcome' => 'answered' })]
    end

    it 'lists the parts with their owners, lanes and end states, the editor and its fallback, as evidence and as a warning' do
      result = score('Ответ.', events: events, council: true)
      council = result[:evidence][:council]

      expect(council).to include(started: 1, participants: ['Администратор', 'Запись к врачу'], outcome: 'answered', editor_fallback: 'timeout',
                                 edited: { language: 'kk', handoff: true, reason: 'council_unresolved' })
      expect(council[:parts]).to contain_exactly(
        a_hash_including(part: 'p1-aaaaa', owner: 'Запись к врачу', lane: 'write', inline: true, state: 'waiting_customer', status: 'needs_information',
                         acted: false, tools_called: 2, turns: 3),
        a_hash_including(part: 'p2-bbbbb', owner: 'Администратор', lane: 'read', state: 'unfinished')
      )
      expect(result[:warnings]).to eq(['council_editor_fallback:timeout'])
    end

    it 'warns when a council is expected and no part started, and has no council evidence for a turn without one' do
      none = score('Ответ.', events: [coordination('captain.council.started')], council: true)
      plain = score('Ответ.', scorer: fresh_scorer)

      expect(none[:warnings]).to eq(['council_expected_but_no_part_started'])
      expect(plain[:evidence]).not_to have_key(:council)
      expect(plain[:warnings]).to be_empty
    end
  end

  describe 'council_changed_hands' do
    let(:routing) { ->(after) { { before: { current_assistant_id: planner.id, routing_revision: 2 }, after: after } } }

    it 'fails a council turn that changed the current agent or the routing revision' do
      same = score('Ответ.', council: true, events: [coordination('captain.council.started')], call: { routing: routing.call(current_assistant_id: planner.id, routing_revision: 2) })
      moved = score('Ответ.', council: true, events: [coordination('captain.council.started')], scorer: fresh_scorer,
                              call: { routing: routing.call(current_assistant_id: owner.id, routing_revision: 3) })

      expect(failure_ids(same)).to be_empty
      expect(failure_ids(moved)).to eq(['council_changed_hands'])
      expect(moved[:failures].first[:detail]).to eq("agent #{planner.id} -> #{owner.id}, routing revision 2 -> 3")
      expect(moved).to include(routing: routing.call(current_assistant_id: owner.id, routing_revision: 3))
    end

    it 'does not put the check to a turn without a council, or without the routing' do
      expect(failure_ids(score('Ответ.', call: { routing: routing.call(current_assistant_id: owner.id, routing_revision: 9) }))).to be_empty
      expect(failure_ids(score('Ответ.', council: true, events: [coordination('captain.council.started')], scorer: fresh_scorer))).to be_empty
    end
  end

  describe 'a person asked for and the staff handoff expected' do
    it 'passes a turn that hands over and gives no failure of any kind' do
      result = score('conversation_handoff', customer: 'позовите оператора', events: [tool_event('handoff')], handoff_tool_called: true,
                                             expect: { staff_handoff: true, must_call: ['handoff'], reply_language: 'ru', must_not_call: ['create_appointment'] })

      expect(result).to include(status: 'pass', handoff: include(observed: true, tool: true), human_request: { value: true, source: 'detector' })
    end
  end
end
