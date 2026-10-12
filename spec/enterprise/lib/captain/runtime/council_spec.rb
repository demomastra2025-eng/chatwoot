require 'rails_helper'
require 'timeout'

RSpec.describe Captain::Runtime::Council do
  let(:context) { { parts: [], state: { assistant_id: 1 }, agent_graph: [{ id: 1 }, { id: 2 }] } }
  let(:council) { described_class.new(context: context, graph: nil, account: nil) }

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

  it 'reassigns an out-of-scope part at most once' do
    first_runtime = Captain::Runtime::Agent.new(name: 'assistant_1', instructions: 'First')
    second_runtime = Captain::Runtime::Agent.new(name: 'assistant_2', instructions: 'Second')
    first_actor = double('first actor', id: 1, agent: first_runtime)
    second_actor = double('second actor', id: 2, agent: second_runtime)
    graph = double('graph', find: second_actor)
    instance = described_class.new(context: context, graph: graph, account: nil)
    allow(instance).to receive(:fresh_actor).with(1).and_return(first_actor)
    allow(instance).to receive(:fresh_actor).with(2).and_return(second_actor)
    allow(instance).to receive(:consult_snapshot).and_return({})
    runner = double('runner')
    allow(Captain::Runtime::Runner).to receive(:new).and_return(runner)
    allow(runner).to receive(:run).and_return(
      double(error: nil, output: { status: 'out_of_scope', suggested_agent_id: 2 }.to_json),
      double(error: nil, output: { status: 'out_of_scope', suggested_agent_id: 1 }.to_json)
    )

    result = instance.send(:consult, { 'executor_agent_id' => 1, 'fragment' => 'Запрос' })

    expect(runner).to have_received(:run).twice
    expect(result['_participants']).to eq([1, 2])
    expect(result['status']).to eq('out_of_scope')
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
end
