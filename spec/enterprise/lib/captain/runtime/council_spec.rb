require 'rails_helper'
require 'timeout'

RSpec.describe Captain::Runtime::Council do
  let(:context) { { parts: [], state: { assistant_id: 1 }, agent_graph: [{ id: 1 }, { id: 2 }] } }
  let(:council) { described_class.new(context: context, graph: nil, account: nil) }
  let(:composer) { instance_double(Captain::Runtime::CouncilComposer) }

  def composer_failure(reason = 'timeout')
    Captain::Runtime::CouncilComposer::Outcome.new(reply: nil, reason: reason)
  end

  # The assembly specs below check the fixed templates, the fallback of the composer: it is never available here.
  before do
    allow(Captain::Runtime::CouncilComposer).to receive(:new).and_return(composer)
    allow(composer).to receive(:compose).and_return(composer_failure)
  end

  def parts(patients)
    patients.each_with_index.map do |patient, index|
      { 'id' => "part-#{index}", 'version' => 1, 'executor_agent_id' => index + 1,
        'fragment' => "Запрос #{index}", 'patient' => patient, 'state' => 'open', 'delivered' => [] }
    end.tap { |items| context[:parts] = items.deep_dup }
  end

  def result(field:, patient:, fragment: '')
    { 'status' => 'needs_information', 'fragment' => fragment, 'missing_fields' => [
      { 'patient' => patient, 'field' => field, 'purpose' => 'запись' }
    ], 'contradictions' => [], 'proposed_operation' => nil }
  end

  it 'asks the same field for one patient once' do
    items = parts(%w[Анна Анна])
    reply = council.send(:assemble, items, [result(field: 'дата', patient: 'Анна'), result(field: 'дата', patient: 'Анна')])

    # One patient: the question is asked once and needs no name prefix.
    expect(reply.scan('дата').size).to eq(1)
    expect(reply).not_to include('Анна — ')
    expect(context[:parts].pluck('state')).to eq(%w[waiting_customer waiting_customer])
  end

  it 'keeps two patients separate and leaves a contradictory part open' do
    items = parts(%w[Анна Борис])
    conflicting = result(field: 'дата', patient: 'Борис', fragment: 'Непроверенный ответ')
    conflicting['contradictions'] = ['Different source values']
    reply = council.send(:assemble, items, [result(field: 'дата', patient: 'Анна'), conflicting])

    expect(reply).to include('дата')
    expect(reply).not_to include('Борис', 'Непроверенный ответ')
    expect(context[:parts].last['state']).to eq('open')
  end

  it 'asks separately for the same field for different patients' do
    items = parts(%w[Анна Борис])
    reply = council.send(:assemble, items, [result(field: 'дата', patient: 'Анна'),
                                            result(field: 'дата', patient: 'Борис')])

    expect(reply).to include('Анна — дата', 'Борис — дата')
  end

  it 'sends consultant questions as they are and never shows role labels' do
    items = parts(%w[собеседник Аружан])
    reply = council.send(:assemble, items, [result(field: 'На какой день вам удобно?', patient: 'собеседник'),
                                            result(field: 'Какая дата рождения Аружан?', patient: 'Аружан')])

    expect(reply).to include('На какой день вам удобно?', 'Какая дата рождения Аружан?')
    expect(reply).not_to include('собеседник', 'Уточните:')
  end

  it 'asks for confirmation and records the proposal without executing it' do
    items = parts(%w[Анна Борис])
    allow(council).to receive(:operation_valid?).and_return(true, false)
    results = [
      { 'status' => 'ok', 'fragment' => 'Время свободно.', 'missing_fields' => [],
        'contradictions' => [], 'proposed_operation' => { 'type' => 'create_appointment', 'params' => { 'slot_id' => 9 } } },
      { 'status' => 'ok', 'fragment' => 'Стоимость уточнена.', 'missing_fields' => [],
        'contradictions' => [], 'proposed_operation' => nil }
    ]

    reply = council.send(:assemble, items, results)

    expect(reply).to include('Время свободно.', 'Стоимость уточнена.', 'Подтвердите действие')
    expect(context[:parts].first['state']).to eq('waiting_confirmation')
    expect(context[:parts].first['proposed_operation']).to eq(results.first['proposed_operation'])
  end

  it 'asks for confirmation of a dependent part that has a prerequisite but withholds a conditional one' do
    results = [1, 2].map do |slot|
      { 'status' => 'ok', 'fragment' => "Вариант #{slot}.", 'missing_fields' => [], 'contradictions' => [],
        'proposed_operation' => { 'type' => 'create_appointment', 'params' => { 'slot_id' => slot } } }
    end
    allow(council).to receive(:operation_valid?).and_return(true)

    dependent = parts(%w[Анна Анна])
    dependent.last.merge!('relation' => 'depends_on', 'depends_on_part_id' => dependent.first['id'])
    council.send(:assemble, dependent, results)
    expect(context[:parts].pluck('state')).to eq(%w[waiting_confirmation waiting_confirmation])

    conditional = parts(%w[Анна Анна])
    conditional.last['relation'] = 'conditional'
    reply = council.send(:assemble, conditional, results)
    expect(context[:parts].pluck('state')).to eq(%w[waiting_confirmation open])
    expect(reply).to include('Часть запроса требует дополнительной проверки.')
  end

  it 'withholds a fragment when its proposed action is unavailable' do
    items = parts(%w[Анна Борис])
    unsafe = { 'status' => 'ok', 'fragment' => 'Запись выполнена.', 'missing_fields' => [],
               'contradictions' => [], 'proposed_operation' => { 'type' => 'unknown_action', 'params' => {} } }
    safe = { 'status' => 'ok', 'fragment' => 'Цена подтверждена.', 'missing_fields' => [],
             'contradictions' => [], 'proposed_operation' => nil }
    allow(council).to receive(:operation_valid?).and_return(false)

    reply = council.send(:assemble, items, [unsafe, safe])

    expect(reply).to include('Цена подтверждена.', 'Часть запроса требует дополнительной проверки.')
    expect(reply).not_to include('Запись выполнена.')
    expect(context[:parts].first['state']).to eq('open')
  end

  describe 'reassigning an out-of-scope part' do
    let(:first_actor) do
      double('first actor', id: 1, name: 'Администратор', agent: Captain::Runtime::Agent.new(name: 'assistant_1', instructions: 'First'))
    end
    let(:second_actor) do
      double('second actor', id: 2, name: 'Лаборатория', agent: Captain::Runtime::Agent.new(name: 'assistant_2', instructions: 'Second'))
    end
    let(:graph) { double('graph', agents: [first_actor, second_actor]) }
    let(:instance) { described_class.new(context: context, graph: graph, account: nil) }
    let(:runner) { double('runner') }

    def out_of_scope(**suggestion)
      double(error: nil, output: { status: 'out_of_scope' }.merge(suggestion).to_json)
    end

    before do
      allow(instance).to receive(:fresh_actor).with(1).and_return(first_actor)
      allow(instance).to receive(:fresh_actor).with(2).and_return(second_actor)
      allow(instance).to receive(:consult_snapshot).and_return({})
      allow(Captain::Runtime::Runner).to receive(:new).and_return(runner)
    end

    it 'follows the agent name the consultant gives, ignoring case and quotes, at most once' do
      allow(runner).to receive(:run).and_return(out_of_scope(suggested_agent: ' «лаборатория» '), out_of_scope(suggested_agent: 'Администратор'))

      result = instance.send(:consult, { 'executor_agent_id' => 1, 'fragment' => 'Запрос' })

      expect(runner).to have_received(:run).twice
      expect(result['_participants']).to eq([1, 2])
      expect(result['status']).to eq('out_of_scope')
    end

    it 'reassigns nothing for an unknown name, for the consultant itself or for a number that only guesses an agent' do
      allow(runner).to receive(:run).and_return(out_of_scope(suggested_agent: 'Регистратура'), out_of_scope(suggested_agent: 'Администратор'),
                                                 out_of_scope(suggested_agent_id: 2, suggested_agent: '2'))

      3.times do
        result = instance.send(:consult, { 'executor_agent_id' => 1, 'fragment' => 'Запрос' })
        expect(result['_participants']).to eq([1])
      end
      expect(runner).to have_received(:run).exactly(3).times
    end

    it 'reassigns nothing when two agents share the suggested name' do
      allow(graph).to receive(:agents).and_return([first_actor, second_actor, double('twin', id: 3, name: ' лаборатория ')])
      allow(runner).to receive(:run).and_return(out_of_scope(suggested_agent: 'Лаборатория'))

      expect(instance.send(:consult, { 'executor_agent_id' => 1, 'fragment' => 'Запрос' })['_participants']).to eq([1])
    end
  end

  it 'gives a consultant the names and responsibilities of the other agents, and never an id' do
    context[:agent_graph] = [{ id: 1, key: 'assistant_1', name: 'Администратор', description: 'Запись' },
                             { id: 2, key: 'assistant_2', name: 'Лаборатория', description: 'Анализы' }]
    actor = double('actor', id: 1, agent_name: 'assistant_1', config: {}, prompt_context_state: {})
    allow(Captain::AssistantSafetyPreferences).to receive(:for).and_return({})

    snapshot = council.send(:consult_snapshot, actor, { 'id' => 'part-1', 'version' => 1, 'executor_agent_id' => 1 })

    expect(snapshot[:consult_peers]).to eq([{ name: 'Лаборатория', description: 'Анализы' }])
    expect(snapshot).not_to have_key(:agent_graph)
  end

  it 'starts independent consultations before waiting for their results' do
    items = parts(%w[Анна Борис])
    started = Queue.new
    release = Queue.new
    first = double('first contributor', id: 1, name: 'Первый', avatar_url: nil)
    second = double('second contributor', id: 2, name: 'Второй', avatar_url: nil)
    graph = double('graph')
    allow(graph).to receive(:find).with(1).and_return(first)
    allow(graph).to receive(:find).with(2).and_return(second)
    instance = described_class.new(context: context, graph: graph, account: nil)
    allow(instance).to receive(:consult) do |part|
      started << part['id']
      release.pop
      { 'status' => 'ok', '_participants' => [part['executor_agent_id']] }
    end
    allow(instance).to receive(:assemble).and_return('Ответ')

    worker = Thread.new { instance.run(items) }
    2.times { Timeout.timeout(5) { started.pop } }
    2.times { release << true }

    expect(worker.value).to eq('Ответ')
    expect(context[:council_contributors].pluck(:id)).to eq([1, 2])
  ensure
    2.times { release << true } if release
    worker&.join(1)
  end

  it 'falls back to the templates in the customer language when the composer produces nothing' do
    context[:captain_v2_current_input] = 'Қабылдау қанша тұрады?'
    unavailable = { 'status' => 'unavailable', 'fragment' => '', 'missing_fields' => [], 'contradictions' => [], 'proposed_operation' => nil }

    reply = council.send(:assemble, parts(%w[Анна]), [unavailable])

    expect(reply).to eq('Сұраудың бір бөлігін қосымша тексеру қажет.')
  end

  it 'asks for missing fields in Kazakh in the fallback template when the customer writes Kazakh' do
    context[:captain_v2_current_input] = 'Қабылдау қанша тұрады?'

    reply = council.send(:assemble, parts(%w[Анна]), [result(field: 'күні', patient: 'Анна')])

    expect(reply).to eq('Нақтылаңыз: күні.')
  end

  describe 'the composed reply' do
    let(:actor) do
      instance_double(Captain::Assistant, id: 1, resolved_agent_model: 'openai/gpt-6-luna', handoff_enabled?: true,
                                          selected_agent_tool_ids: %w[faq_lookup handoff])
    end
    let(:graph) { instance_double(Captain::AgentGraph, find: actor, entry: actor) }
    let(:council) { described_class.new(context: context, graph: graph, account: nil, llm_context: :llm_context) }
    let(:calls) { [] }
    let(:composed_text) { 'Приём стоит 5000 тенге. Подтверждаете запись Анны?' }

    def answered(fragment, facts: [], operation: nil, status: 'ok')
      { 'status' => status, 'fragment' => fragment, 'facts' => facts, 'missing_fields' => [],
        'contradictions' => [], 'proposed_operation' => operation }
    end

    before do
      context[:state][:conversation] = { id: 7 }
      context[:captain_v2_current_input] = 'Сколько стоит приём? И запишите Анну завтра'
      allow(composer).to receive(:compose) do |**kwargs|
        calls << kwargs
        Captain::Runtime::CouncilComposer::Outcome.new(reply: composed_text)
      end
      allow(Captain::Runtime::CoordinationEvents).to receive(:council_composed)
      allow(Captain::Runtime::CoordinationEvents).to receive(:council_composer_fallback)
    end

    it 'is the reply when the composer produced one, built from part data without identifiers or role labels' do
      items = parts(%w[собеседник Борис])
      allow(council).to receive(:operation_valid?).and_return(true, false)
      operation = { 'type' => 'create_appointment',
                    'params' => { 'slot_id' => 9, 'doctor_id' => 4, 'starts_at' => '2026-10-14T10:00', 'service_name' => 'Приём терапевта' } }
      results = [answered('Время свободно.',
                          facts: [{ 'fact' => 'Окно 10:00', 'source' => 'расписание', 'slot_id' => 9, 'slotId' => 9, 'doctorUuid' => 'x' }],
                          operation: operation),
                 answered('Приём стоит 5000 тенге.', facts: [{ 'fact' => 'Цена 5000', 'source' => 'прайс' }])]

      reply = council.send(:assemble, items, results)

      expect(reply).to eq(composed_text)
      expect(calls.sole).to include(message: 'Сколько стоит приём? И запишите Анну завтра', language: 'ru', staff_handoff: false)
      expect(calls.sole[:parts]).to eq(
        [
          { 'request' => 'Запрос 0', 'answer' => 'Время свободно.', 'facts' => [{ 'fact' => 'Окно 10:00', 'source' => 'расписание' }],
            'confirm' => { 'action' => 'запись на приём',
                           'details' => { 'starts_at' => '2026-10-14T10:00', 'service_name' => 'Приём терапевта' } } },
          { 'request' => 'Запрос 1', 'patient' => 'Борис', 'answer' => 'Приём стоит 5000 тенге.',
            'facts' => [{ 'fact' => 'Цена 5000', 'source' => 'прайс' }] }
        ]
      )
      expect(context[:parts].pluck('state')).to eq(%w[waiting_confirmation answered])
      expect(Captain::Runtime::CoordinationEvents).to have_received(:council_composed)
        .with(context: context, part_ids: %w[part-0 part-1], language: 'ru', handoff: false)
    end

    it 'names the patient in the confirmation data of a waiting operation' do
      items = parts(%w[Анна])
      allow(council).to receive(:operation_valid?).and_return(true)
      operation = { 'type' => 'update_appointment', 'params' => { 'appointment_id' => 3, 'new_time' => '11:00' } }

      council.send(:assemble, items, [answered('Время свободно.', operation: operation)])

      expect(calls.sole[:parts].sole['confirm']).to eq(
        'action' => 'изменение записи', 'patient' => 'Анна', 'details' => { 'new_time' => '11:00' }
      )
    end

    it 'names the action in Kazakh for a Kazakh customer and never by the English title of the tool' do
      context[:captain_v2_current_input] = 'Қабылдау қанша тұрады?'
      allow(council).to receive(:operation_valid?).and_return(true)
      operation = { 'type' => 'cancel_appointment', 'params' => { 'appointment_id' => 3 } }

      council.send(:assemble, parts(%w[Анна]), [answered('Уақыт бос.', operation: operation)])

      expect(calls.sole[:parts].sole['confirm']).to eq('action' => 'жазылуды болдырмау', 'patient' => 'Анна')
    end

    it 'leaves the action out for a tool without a label and still marks the part as awaiting yes or no' do
      allow(council).to receive(:operation_valid?).and_return(true)
      operation = { 'type' => 'create_deal', 'params' => { 'deal_id' => 3 } }

      council.send(:assemble, parts(%w[собеседник]), [answered('Готово к оформлению.', operation: operation)])

      expect(calls.sole[:parts].sole['confirm']).to eq('yes_no' => true)
    end

    it 'shows a UTC timestamp as the local clock of the clinic' do
      account = instance_double(Account, reporting_timezone: 'Asia/Almaty')
      local = described_class.new(context: context, graph: graph, account: account, llm_context: :llm_context)
      allow(local).to receive(:operation_valid?).and_return(true)
      operation = { 'type' => 'create_appointment', 'params' => { 'starts_at' => '2026-10-14T05:00:00Z', 'ends_at' => '2026-10-14T10:30' } }

      local.send(:assemble, parts(%w[Анна]), [answered('Время свободно.', operation: operation)])

      expect(calls.sole[:parts].sole.dig('confirm', 'details')).to eq('starts_at' => '2026-10-14T10:00', 'ends_at' => '2026-10-14T10:30')
    end

    it 'detects Kazakh from the customer message' do
      context[:captain_v2_current_input] = 'Қабылдау қанша тұрады?'

      council.send(:assemble, parts(%w[Анна]), [answered('Баға 5000.')])

      expect(calls.sole).to include(language: 'kk')
      expect(Captain::Runtime::CoordinationEvents).to have_received(:council_composed).with(hash_including(language: 'kk'))
    end

    it 'asks each missing item once per patient and shows no role label' do
      context[:agent_graph] = [{ id: 1 }, { id: 2 }, { id: 3 }]
      items = parts(%w[Анна Анна собеседник])
      results = [result(field: 'На какую дату?', patient: 'Анна'), result(field: 'На какую дату?', patient: 'Анна'),
                 result(field: 'Удобное время?', patient: 'собеседник')]

      council.send(:assemble, items, results)

      questions = calls.sole[:parts].flat_map { |part| part['questions'].to_a }
      expect(questions).to eq([{ 'patient' => 'Анна', 'question' => 'На какую дату?' }, { 'question' => 'Удобное время?' }])
    end

    it 'marks an unresolved part, lets the composer offer staff and requests a real handoff after the reply' do
      items = parts(%w[Анна Борис])
      items.last['fragment'] = 'Результаты анализов'
      context[:parts] = items.deep_dup

      reply = council.send(:assemble, items, [answered('Приём стоит 5000 тенге.'), answered('', status: 'unavailable')])

      expect(reply).to eq(composed_text)
      expect(calls.sole).to include(staff_handoff: true)
      expect(calls.sole[:parts].last).to eq('request' => 'Результаты анализов', 'patient' => 'Борис', 'unresolved' => true)
      expect(context[:council_handoff]).to eq(reason: 'council_unresolved', parts: ['Результаты анализов'])
      expect(context[:parts].pluck('state')).to eq(%w[answered unknown])
      expect(Captain::Runtime::CoordinationEvents).to have_received(:council_composed).with(hash_including(handoff: true))
    end

    it 'treats a withheld and an out-of-scope part as unresolved and never passes their draft on' do
      items = parts(%w[Анна Борис])
      conflicting = answered('Непроверенный ответ', facts: [{ 'fact' => 'x', 'source' => 'y' }]).merge('contradictions' => ['Другое значение'])
      out_of_scope = answered('Не моя тема', status: 'out_of_scope')

      council.send(:assemble, items, [conflicting, out_of_scope])

      expect(calls.sole[:parts]).to eq([{ 'request' => 'Запрос 0', 'patient' => 'Анна', 'unresolved' => true },
                                        { 'request' => 'Запрос 1', 'patient' => 'Борис', 'unresolved' => true }])
      expect(context[:council_handoff][:parts]).to eq(['Запрос 0', 'Запрос 1'])
    end

    it 'sends a consultant question without missing fields to the customer and hands nothing to staff' do
      council.send(:assemble, parts(%w[Анна]), [answered('К какому врачу вы хотите записаться?', status: 'needs_information')])

      expect(calls.sole).to include(staff_handoff: false)
      expect(calls.sole[:parts].sole).to eq('request' => 'Запрос 0', 'patient' => 'Анна', 'answer' => 'К какому врачу вы хотите записаться?')
      expect(context).not_to have_key(:council_handoff)
      expect(context[:parts].sole['state']).to eq('unknown')
    end

    it 'still treats a needs_information result without any question as unresolved' do
      council.send(:assemble, parts(%w[Анна]), [answered('', status: 'needs_information')])

      expect(calls.sole).to include(staff_handoff: true)
      expect(calls.sole[:parts].sole).to include('unresolved' => true)
      expect(context[:council_handoff]).to eq(reason: 'council_unresolved', parts: ['Запрос 0'])
    end

    it 'requests no handoff and promises no staff while another part waits for the customer’s confirmation' do
      items = parts(%w[Анна Борис])
      allow(council).to receive(:operation_valid?).and_return(true, false)
      operation = { 'type' => 'create_appointment', 'params' => { 'starts_at' => '2026-10-14T10:00' } }

      council.send(:assemble, items, [answered('Время свободно.', operation: operation), answered('', status: 'unavailable')])

      expect(calls.sole).to include(staff_handoff: false)
      expect(calls.sole[:parts].last).to include('unresolved' => true)
      expect(context).not_to have_key(:council_handoff)
      expect(context[:parts].pluck('state')).to eq(%w[waiting_confirmation unknown])
    end

    it 'promises staff nothing and requests no handoff when the agent cannot hand off' do
      allow(actor).to receive(:handoff_enabled?).and_return(false)

      council.send(:assemble, parts(%w[Анна]), [answered('', status: 'unavailable')])

      expect(calls.sole).to include(staff_handoff: false)
      expect(context).not_to have_key(:council_handoff)
    end

    it 'requests no handoff when the run has no conversation' do
      context[:state].delete(:conversation)

      council.send(:assemble, parts(%w[Анна]), [answered('', status: 'unavailable')])

      expect(calls.sole).to include(staff_handoff: false)
      expect(context).not_to have_key(:council_handoff)
    end

    it 'keeps the template reply, requests no handoff and reports why when the composer produces nothing' do
      allow(composer).to receive(:compose).and_return(composer_failure('success_claim'))
      allow(council).to receive(:operation_valid?).and_return(true)
      operation = { 'type' => 'create_appointment', 'params' => { 'slot_id' => 9 } }

      reply = council.send(:assemble, parts(%w[Анна Борис]), [answered('Время свободно.', operation: operation), answered('', status: 'unavailable')])

      expect(reply).to eq("Время свободно.\n\nПодтвердите действие по запросу «Запрос 0»?\n\nЧасть запроса требует дополнительной проверки.")
      expect(context).not_to have_key(:council_handoff)
      expect(Captain::Runtime::CoordinationEvents).to have_received(:council_composer_fallback)
        .with(context: context, part_ids: %w[part-0 part-1], reason: 'success_claim')
      expect(Captain::Runtime::CoordinationEvents).not_to have_received(:council_composed)
    end

    it 'keeps the template reply when the composer itself fails' do
      allow(composer).to receive(:compose).and_raise(StandardError, 'boom')

      reply = council.send(:assemble, parts(%w[Анна]), [answered('Приём стоит 5000 тенге.')])

      expect(reply).to eq('Приём стоит 5000 тенге.')
      expect(Captain::Runtime::CoordinationEvents).to have_received(:council_composer_fallback).with(hash_including(reason: 'error'))
    end

    it 'composes with the model of the acting agent unless the runner passes its own' do
      council.send(:assemble, parts(%w[Анна]), [answered('Баға 5000.')])
      expect(Captain::Runtime::CouncilComposer).to have_received(:new).with(
        context: context, graph: graph, account: nil, llm_context: :llm_context, model: 'openai/gpt-6-luna'
      )

      runner_model = described_class.new(context: context, graph: graph, account: nil, model: 'openai/gpt-6-sol')
      runner_model.send(:assemble, parts(%w[Анна]), [answered('Баға 5000.')])
      expect(Captain::Runtime::CouncilComposer).to have_received(:new).with(hash_including(model: 'openai/gpt-6-sol'))
    end
  end
end
