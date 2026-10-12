require 'rails_helper'
require 'timeout'

RSpec.describe Captain::Runtime::Council do
  let(:context) { { parts: [], state: { assistant_id: 1 }, agent_graph: [{ id: 1 }, { id: 2 }] } }
  let(:council) { described_class.new(context: context, graph: nil, account: nil) }
  let(:composer) { instance_double(Captain::Runtime::CouncilComposer) }
  let(:cannot_answer) { 'На этот вопрос я сейчас не могу ответить.' }
  let(:staff_will_answer) { 'По этому вопросу вам ответит сотрудник клиники.' }
  let(:proposal) { { 'type' => 'create_appointment', 'params' => { 'slot_id' => 9, 'starts_at' => '2026-10-14T10:00' } } }

  def composer_failure(reason = 'timeout')
    Captain::Runtime::CouncilComposer::Outcome.new(reply: nil, reason: reason)
  end

  # The assembly specs below check what goes out when the composer produces nothing: the texts of the parts in order.
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

  # What a consultation returns after it is parsed: the final text of the part and the structured result.
  def consulted(text, status: 'ok', questions: [], operation: nil, contradictions: [], facts: [{ 'fact' => 'x', 'source' => 'y' }])
    { 'status' => status, 'customer_text' => text, 'facts' => facts, 'contradictions' => contradictions,
      'missing_fields' => questions.map { |question| { 'patient' => 'Анна', 'field' => question, 'purpose' => 'запись' } },
      'proposed_operation' => operation }
  end

  def failed
    consulted('', status: 'unavailable', facts: [])
  end

  it 'sends the part texts in the order of the requests, a blank line apart, when the composer produces nothing' do
    reply = council.send(:assemble, parts(%w[Анна Борис]), [consulted('Приём стоит 5000 тенге.'), consulted('Мы находимся на улице Абая, 1.')])

    expect(reply).to eq("Приём стоит 5000 тенге.\n\nМы находимся на улице Абая, 1.")
    expect(context[:parts].pluck('state')).to eq(%w[answered answered])
  end

  it 'sends the question of a consultant as it is and keeps the part waiting for the customer' do
    question = 'На какой день вам удобно?'

    reply = council.send(:assemble, parts(%w[Анна]), [consulted(question, status: 'needs_information', questions: [question])])

    expect(reply).to eq(question)
    expect(context[:parts].sole['state']).to eq('waiting_customer')
    expect(context[:parts].sole['missing_fields'].pluck('field')).to eq([question])
  end

  it 'asks the missing fields itself, without a label, when the consultant wrote no text' do
    reply = council.send(:assemble, parts(%w[Анна]), [consulted('', status: 'needs_information', questions: ['На какой день вам удобно?'])])

    expect(reply).to eq('На какой день вам удобно?')
    expect(context[:parts].sole['state']).to eq('waiting_customer')
  end

  it 'keeps a contradictory part open, never passes its text on and says honestly that it cannot be answered' do
    question = 'На какую дату?'
    items = parts(%w[Анна Борис])
    conflicting = consulted('Непроверенный ответ', contradictions: ['Different source values'])

    reply = council.send(:assemble, items, [consulted('', status: 'needs_information', questions: [question]), conflicting])

    expect(reply).to eq("#{question}\n\n#{cannot_answer}")
    expect(context[:parts].pluck('state')).to eq(%w[waiting_customer open])
  end

  it 'asks for confirmation with the question of the consultant and records the proposal without executing it' do
    question = 'Записать вас к терапевту Иванову на 14 октября в 10:00?'
    items = parts(%w[Анна Борис])
    allow(council).to receive(:operation_valid?).and_return(true, false)

    reply = council.send(:assemble, items, [consulted(question, operation: proposal), consulted('Стоимость приёма 5000 тенге.')])

    expect(reply).to eq("#{question}\n\nСтоимость приёма 5000 тенге.")
    expect(context[:parts].pluck('state')).to eq(%w[waiting_confirmation answered])
    expect(context[:parts].first['proposed_operation']).to eq(proposal)
  end

  it 'stores no proposal for a confirmation the customer was not asked about' do
    allow(council).to receive(:operation_valid?).and_return(true)

    reply = council.send(:assemble, parts(%w[Анна]), [consulted('', operation: proposal)])

    expect(reply).to eq(cannot_answer)
    expect(context[:parts].sole['state']).to eq('unknown')
    expect(context[:parts].sole['proposed_operation']).to be_blank
  end

  it 'asks for confirmation of a dependent part that has a prerequisite but withholds a conditional one' do
    results = [1, 2].map { |slot| consulted("Записать вас на вариант #{slot}?", operation: proposal.merge('params' => { 'slot_id' => slot })) }
    allow(council).to receive(:operation_valid?).and_return(true)

    dependent = parts(%w[Анна Анна])
    dependent.last.merge!('relation' => 'depends_on', 'depends_on_part_id' => dependent.first['id'])
    council.send(:assemble, dependent, results)
    expect(context[:parts].pluck('state')).to eq(%w[waiting_confirmation waiting_confirmation])

    conditional = parts(%w[Анна Анна])
    conditional.last['relation'] = 'conditional'
    reply = council.send(:assemble, conditional, results)
    expect(context[:parts].pluck('state')).to eq(%w[waiting_confirmation open])
    expect(reply).to eq("Записать вас на вариант 1?\n\n#{cannot_answer}")
  end

  it 'withholds a text when its proposed action is unavailable' do
    unsafe = consulted('Запись выполнена.', operation: { 'type' => 'unknown_action', 'params' => {} })
    allow(council).to receive(:operation_valid?).and_return(false)

    reply = council.send(:assemble, parts(%w[Анна Борис]), [unsafe, consulted('Цена подтверждена.')])

    expect(reply).to eq("#{cannot_answer}\n\nЦена подтверждена.")
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

  it 'uses one short line in the customer language for a part without any text' do
    context[:captain_v2_current_input] = 'Қабылдау қанша тұрады?'

    reply = council.send(:assemble, parts(%w[Анна]), [failed])

    expect(reply).to eq('Бұл сұраққа қазір жауап бере алмаймын.')
  end

  it 'sends the stock line once when several parts have no text and the composer produces nothing' do
    reply = council.send(:assemble, parts(%w[Анна Борис]), [failed, failed])

    expect(reply).to eq(cannot_answer)
    expect(context[:parts].pluck('state')).to eq(%w[unknown unknown])
  end

  it 'drops a question repeated for the same person but keeps the same words asked about different people' do
    question = 'На какую дату?'
    asked = consulted(question, status: 'needs_information', questions: [question])

    expect(council.send(:assemble, parts(['Анна', ' анна ']), [asked, asked])).to eq(question)
    expect(council.send(:assemble, parts(%w[Анна Борис]), [asked, asked])).to eq("#{question}\n\n#{question}")
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

  describe 'the result of a consultation' do
    def parsed(output)
      council.send(:parse_result, double(error: nil, output: output.to_json))
    end

    let(:fact) { { 'fact' => 'Цена 5000', 'source' => 'прайс' } }

    it 'carries the final text of the part, trimmed' do
      result = parsed(status: 'ok', customer_text: "  Приём стоит 5000 тенге.\n", facts: [fact])

      expect(result).to include('status' => 'ok', 'customer_text' => 'Приём стоит 5000 тенге.')
    end

    it 'does not pass on the text of an answer without a verified fact' do
      result = parsed(status: 'ok', customer_text: 'Приём стоит 5000 тенге.', facts: [{ 'fact' => 'Цена 5000' }])

      expect(result).to include('status' => 'unavailable', 'customer_text' => '')
    end

    it 'keeps the honest sentence of a consultant that cannot resolve the part' do
      result = parsed(status: 'unavailable', customer_text: 'На этот вопрос я сейчас не могу ответить.')

      expect(result).to include('status' => 'unavailable', 'customer_text' => 'На этот вопрос я сейчас не могу ответить.')
    end

    it 'treats a missing or malformed text as no text' do
      expect(parsed(status: 'ok', facts: [fact])).to include('customer_text' => '')
      expect(parsed(status: 'ok', customer_text: { 'a' => 1 }, facts: [fact])).to include('customer_text' => '')
    end
  end

  describe 'what a consultant is told' do
    let(:actor) { double('consultant', id: 2, agent_name: 'assistant_2', config: {}, prompt_context_state: {}) }

    before { allow(Captain::AssistantSafetyPreferences).to receive(:for).and_return({}) }

    def snapshot_for(instance)
      instance.send(:consult_snapshot, actor, { 'id' => 'part-0', 'version' => 1 })
    end

    it 'is the language of the customer and that no staff member can take a part over without a handoff' do
      context[:captain_v2_current_input] = 'Қабылдау қанша тұрады?'

      expect(snapshot_for(council)).to include(consult_mode: true, consult_language: 'kk', consult_staff_handoff: false)
    end

    it 'is Russian and that staff can take a part over when the agent has a handoff' do
      entry = instance_double(Captain::Assistant, id: 1, handoff_enabled?: true, selected_agent_tool_ids: %w[faq_lookup handoff])
      graph = instance_double(Captain::AgentGraph, find: entry, entry: entry)
      context[:state][:conversation] = { id: 7 }
      context[:captain_v2_current_input] = 'Сколько стоит приём?'

      snapshot = snapshot_for(described_class.new(context: context, graph: graph, account: nil))

      expect(snapshot).to include(consult_language: 'ru', consult_staff_handoff: true)
    end
  end

  describe 'the composed reply' do
    let(:actor) do
      instance_double(Captain::Assistant, id: 1, resolved_agent_model: 'openai/gpt-6-luna', handoff_enabled?: true,
                                          selected_agent_tool_ids: %w[faq_lookup handoff])
    end
    let(:graph) { instance_double(Captain::AgentGraph, find: actor, entry: actor) }
    let(:council) { described_class.new(context: context, graph: graph, account: nil, llm_context: :llm_context) }
    let(:calls) { [] }
    let(:composed_text) { 'Приём стоит 5000 тенге. Записать вас к терапевту Иванову на 14 октября в 10:00?' }

    def line(text, confirmation: false, staff: false)
      { 'text' => text, 'needs_confirmation' => confirmation, 'staff_will_answer' => staff }
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

    it 'is the reply of the composer, written from the part texts without data, identifiers or role labels' do
      question = 'Записать вас к терапевту Иванову на 14 октября в 10:00?'
      items = parts(%w[собеседник Борис])
      allow(council).to receive(:operation_valid?).and_return(true, false)
      facts = [{ 'fact' => 'Окно 10:00', 'source' => 'расписание', 'slot_id' => 9 }]

      reply = council.send(:assemble, items, [consulted(question, facts: facts, operation: proposal),
                                              consulted('Приём стоит 5000 тенге.')])

      expect(reply).to eq(composed_text)
      expect(calls.sole).to eq(message: 'Сколько стоит приём? И запишите Анну завтра', language: 'ru',
                               parts: [line(question, confirmation: true), line('Приём стоит 5000 тенге.')])
      expect(context[:parts].pluck('state')).to eq(%w[waiting_confirmation answered])
      expect(context).not_to have_key(:council_handoff)
      expect(Captain::Runtime::CoordinationEvents).to have_received(:council_composed)
        .with(context: context, part_ids: %w[part-0 part-1], language: 'ru', handoff: false)
      expect(Captain::Runtime::CoordinationEvents).not_to have_received(:council_composer_fallback)
    end

    it 'detects Kazakh from the customer message' do
      context[:captain_v2_current_input] = 'Қабылдау қанша тұрады?'

      council.send(:assemble, parts(%w[Анна]), [consulted('Баға 5000 теңге.')])

      expect(calls.sole).to include(language: 'kk')
      expect(Captain::Runtime::CoordinationEvents).to have_received(:council_composed).with(hash_including(language: 'kk'))
    end

    it 'passes the questions of the consultants on as part texts, taking the missing field when a consultant wrote no text' do
      context[:agent_graph] = [{ id: 1 }, { id: 2 }, { id: 3 }]
      items = parts(%w[Анна Анна собеседник])
      results = [consulted('На какую дату?', status: 'needs_information', questions: ['На какую дату?']),
                 consulted('', status: 'needs_information', questions: ['На какую дату?']),
                 consulted('Удобное время?', status: 'needs_information', questions: ['Удобное время?'])]

      council.send(:assemble, items, results)

      expect(calls.sole[:parts].pluck('text')).to eq(['На какую дату?', 'На какую дату?', 'Удобное время?'])
      expect(context[:parts].pluck('state')).to eq(%w[waiting_customer waiting_customer waiting_customer])
    end

    it 'gives an unresolved part without text one line, flags it for staff and requests a real handoff after the reply' do
      items = parts(%w[Анна Борис])
      items.last['fragment'] = 'Результаты анализов'
      context[:parts] = items.deep_dup

      reply = council.send(:assemble, items, [consulted('Приём стоит 5000 тенге.'), failed])

      expect(reply).to eq(composed_text)
      expect(calls.sole[:parts]).to eq([line('Приём стоит 5000 тенге.'), line(staff_will_answer, staff: true)])
      expect(context[:council_handoff]).to eq(reason: 'council_unresolved', parts: ['Результаты анализов'])
      expect(context[:parts].pluck('state')).to eq(%w[answered unknown])
      expect(Captain::Runtime::CoordinationEvents).to have_received(:council_composed).with(hash_including(handoff: true))
    end

    it 'uses the honest sentence of the consultant for an unresolved part and flags it for staff' do
      sentence = 'Результаты анализов вам сообщит сотрудник клиники.'

      council.send(:assemble, parts(%w[Анна]), [consulted(sentence, status: 'unavailable', facts: [])])

      expect(calls.sole[:parts]).to eq([line(sentence, staff: true)])
      expect(context[:council_handoff]).to eq(reason: 'council_unresolved', parts: ['Запрос 0'])
    end

    it 'treats a withheld part as unresolved without its draft and keeps the sentence of an out-of-scope consultant' do
      items = parts(%w[Анна Борис])
      conflicting = consulted('Непроверенный ответ', contradictions: ['Другое значение'])

      council.send(:assemble, items, [conflicting, consulted('Не моя тема', status: 'out_of_scope')])

      expect(calls.sole[:parts]).to eq([line(staff_will_answer, staff: true), line('Не моя тема', staff: true)])
      expect(context[:council_handoff][:parts]).to eq(['Запрос 0', 'Запрос 1'])
    end

    it 'sends a consultant question without missing fields to the customer and hands nothing to staff' do
      question = 'К какому врачу вы хотите записаться?'

      council.send(:assemble, parts(%w[Анна]), [consulted(question, status: 'needs_information')])

      expect(calls.sole[:parts]).to eq([line(question)])
      expect(context).not_to have_key(:council_handoff)
      expect(context[:parts].sole['state']).to eq('unknown')
    end

    it 'still treats a needs_information result without any question as unresolved' do
      council.send(:assemble, parts(%w[Анна]), [consulted('', status: 'needs_information')])

      expect(calls.sole[:parts]).to eq([line(staff_will_answer, staff: true)])
      expect(context[:council_handoff]).to eq(reason: 'council_unresolved', parts: ['Запрос 0'])
    end

    it 'requests no handoff and promises no staff while another part waits for the confirmation of the customer' do
      question = 'Записать вас на 14 октября в 10:00?'
      items = parts(%w[Анна Борис])
      allow(council).to receive(:operation_valid?).and_return(true, false)

      council.send(:assemble, items, [consulted(question, operation: proposal),
                                      consulted('Результаты анализов вам сообщит сотрудник клиники.', status: 'unavailable', facts: [])])

      expect(calls.sole[:parts]).to eq([line(question, confirmation: true), line(cannot_answer)])
      expect(context).not_to have_key(:council_handoff)
      expect(context[:parts].pluck('state')).to eq(%w[waiting_confirmation unknown])
      expect(Captain::Runtime::CoordinationEvents).to have_received(:council_composed).with(hash_including(handoff: false))
    end

    it 'keeps the sentence of the consultant and requests no handoff when the agent cannot hand off' do
      allow(actor).to receive(:handoff_enabled?).and_return(false)
      sentence = 'На этот вопрос я сейчас не могу ответить.'

      council.send(:assemble, parts(%w[Анна Борис]), [consulted(sentence, status: 'unavailable', facts: []), failed])

      expect(calls.sole[:parts]).to eq([line(sentence), line(cannot_answer)])
      expect(context).not_to have_key(:council_handoff)
    end

    it 'requests no handoff when the run has no conversation' do
      context[:state].delete(:conversation)

      council.send(:assemble, parts(%w[Анна]), [failed])

      expect(calls.sole[:parts]).to eq([line(cannot_answer)])
      expect(context).not_to have_key(:council_handoff)
    end

    it 'sends the part texts in order, reports why and still requests the handoff its texts promise when the composer produces nothing' do
      allow(composer).to receive(:compose).and_return(composer_failure('invalid'))

      reply = council.send(:assemble, parts(%w[Анна Борис]), [consulted('Приём стоит 5000 тенге.'), failed])

      expect(reply).to eq("Приём стоит 5000 тенге.\n\n#{staff_will_answer}")
      expect(context[:council_handoff]).to eq(reason: 'council_unresolved', parts: ['Запрос 1'])
      expect(Captain::Runtime::CoordinationEvents).to have_received(:council_composer_fallback)
        .with(context: context, part_ids: %w[part-0 part-1], reason: 'invalid')
      expect(Captain::Runtime::CoordinationEvents).not_to have_received(:council_composed)
    end

    it 'says once that staff will answer when two unresolved parts have no text and the composer produces nothing' do
      allow(composer).to receive(:compose).and_return(composer_failure('error'))

      reply = council.send(:assemble, parts(%w[Анна Борис]), [failed, failed])

      expect(reply).to eq(staff_will_answer)
      expect(context[:council_handoff]).to eq(reason: 'council_unresolved', parts: ['Запрос 0', 'Запрос 1'])
    end

    it 'sends the confirmation question of the consultant when the composer produces nothing' do
      allow(composer).to receive(:compose).and_return(composer_failure('empty'))
      question = 'Записать вас к терапевту Иванову на 14 октября в 10:00?'
      allow(council).to receive(:operation_valid?).and_return(true)

      reply = council.send(:assemble, parts(%w[Анна]), [consulted(question, operation: proposal)])

      expect(reply).to eq(question)
      expect(context).not_to have_key(:council_handoff)
      expect(context[:parts].sole['state']).to eq('waiting_confirmation')
    end

    it 'sends the part texts in order when the composer itself fails' do
      allow(composer).to receive(:compose).and_raise(StandardError, 'boom')

      reply = council.send(:assemble, parts(%w[Анна Борис]), [consulted('Приём стоит 5000 тенге.'), consulted('Адрес: улица Абая, 1.')])

      expect(reply).to eq("Приём стоит 5000 тенге.\n\nАдрес: улица Абая, 1.")
      expect(Captain::Runtime::CoordinationEvents).to have_received(:council_composer_fallback).with(hash_including(reason: 'error'))
    end

    it 'composes with the model of the acting agent unless the runner passes its own' do
      council.send(:assemble, parts(%w[Анна]), [consulted('Баға 5000 теңге.')])
      expect(Captain::Runtime::CouncilComposer).to have_received(:new).with(
        context: context, account: nil, llm_context: :llm_context, model: 'openai/gpt-6-luna'
      )

      runner_model = described_class.new(context: context, graph: graph, account: nil, model: 'openai/gpt-6-sol')
      runner_model.send(:assemble, parts(%w[Анна]), [consulted('Баға 5000 теңге.')])
      expect(Captain::Runtime::CouncilComposer).to have_received(:new).with(hash_including(model: 'openai/gpt-6-sol'))
    end
  end
end
