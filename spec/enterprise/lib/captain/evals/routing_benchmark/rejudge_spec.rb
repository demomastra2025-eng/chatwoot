# frozen_string_literal: true

require 'rails_helper'
require 'rake'
require 'tmpdir'

RSpec.describe Captain::Evals::RoutingBenchmark::Rejudge do
  let(:runner_class) { Captain::Evals::RoutingBenchmark::Runner }
  let(:fixture_data) do
    {
      workspace: {
        agents: [{ name: 'Регистратор', routing_description: 'Запись', instructions: 'Отвечай по-русски.', tool_ids: %w[faq_lookup], model: 'openai/gpt-6-luna' }],
        contacts: [{ key: 'patient', name: 'Дана Нурланова' }],
        resources: [{ key: 'doctor_a', name: 'Терапевт Абдрахманова Сауле' }],
        services: [{ key: 'consult', name: 'Консультация терапевта', duration_min: 30, base_price: 7000 }],
        knowledge: [{ question: 'Где вы находитесь?', answer: 'Центр, улица Абая 10.' }]
      },
      dialogues: [{ id: 'judged', contact: 'patient',
                    rubric: 'Пациент — Дана Нурланова (сама). Во всех ответах: по-русски. Ход 1: Здоровается. Ход 2: Называет адрес.',
                    turns: [{ customer: 'Здравствуйте', rubric: 'Здоровается и спрашивает, чем помочь.', expect: { agent: 'Регистратор', council: false } },
                            { customer: 'Подскажите адрес', rubric: 'Называет адрес из базы знаний.', expect: { agent: 'Регистратор', council: false } }] }]
    }
  end
  let(:replies) { ['Здравствуйте! Чем помочь?', 'Мы находимся в центре, улица Абая 10.'] }
  let(:prompts) { [] }
  let(:account) { create(:account) }
  let(:dir) { Dir.mktmpdir }
  let(:fixture_path) { File.join(dir, 'case.yml') }
  let(:judge_runner) { runner_class.new(fixtures: 'rejudge', runs: 1, budget_usd: 1, out: 'rejudge', judge: true) }

  before do
    File.write(fixture_path, fixture_data.deep_stringify_keys.to_yaml)
    allow(Captain::Llm::UpdateEmbeddingJob).to receive(:perform_now)
    allow(judge_runner).to receive(:judge_pause)
  end

  after { FileUtils.remove_entry(dir) }

  # A report as a run wrote it when the judge could not be called: the TypeError that the runtime used to raise.
  def stored_report
    fixture = Captain::Evals::RoutingBenchmark::Fixture.new(fixture_data)
    allow(Captain::Evals::RoutingBenchmark::Guard).to receive_messages(check!: true, restrict_http!: true)
    allow(Dir).to receive(:glob).and_call_original
    allow(Dir).to receive(:glob).with('synthetic/*.yml').and_return(['synthetic/case.yml'])
    allow(Captain::Evals::RoutingBenchmark::Fixture).to receive(:load).and_call_original
    allow(Captain::Evals::RoutingBenchmark::Fixture).to receive(:load).with('synthetic/case.yml').and_return(fixture)
    calls = 0
    allow(Captain::Assistant::AgentRunnerService).to receive(:new) do |assistant:, **|
      answer = { 'agent_id' => assistant.id, 'response' => replies.fetch(calls), 'captain_request_id' => 'synthetic-request' }
      calls += 1
      instance_double(Captain::Assistant::AgentRunnerService, generate_response: answer)
    end
    allow(Llm::Runtime).to receive(:build_chat).and_raise(TypeError, 'no implicit conversion of nil into Hash')
    runner = runner_class.new(fixtures: 'synthetic/*.yml', runs: 1, budget_usd: 1, out: Rails.root.join('tmp', "rejudge-#{SecureRandom.uuid}.json"), judge: true)
    allow(runner).to receive_messages(write_report: nil, judge_pause: nil)
    JSON.parse(JSON.generate(runner.call))
  end

  # The judge of the new call, after the report of the old one was written.
  def stub_judge(content, cost: 0)
    allow(Llm::Runtime).to receive(:build_chat).and_return(Object.new)
    allow(Llm::Runtime).to receive(:ask) do |_chat, prompt, account:, **|
      prompts << prompt
      LlmEvent.create!(account_id: account.id, event_name: 'llm.chat.complete', model: runner_class::MODEL, estimated_cost: cost,
                       payload: { 'usage_scope' => 'provider_response' }, request_id: 'rejudge-request')
      Struct.new(:content).new(content)
    end
  end

  def rejudge(report, budget_usd: 1, fixture_paths: [fixture_path], **options)
    described_class.new(report, runner: judge_runner, account: account, budget_usd: budget_usd, fixture_paths: fixture_paths, **options).call
  end

  # An older report holds the missing verdict as a failure of the turn (minor, gate none).
  def legacy_report
    stored_report.tap do |report|
      report['cases'].each do |item|
        item.delete('judge')
        item.delete('not_evaluated')
        item['warnings'] = []
        item['status'] = 'fail'
        item['reasons'] = ['judge_unavailable']
        item['evaluated'] += ['judge_unavailable']
        item['failures'] = [{ 'id' => 'judge_unavailable', 'check' => 'judge_unavailable', 'severity' => 'minor', 'gate' => 'none', 'detail' => 'TypeError' }]
      end
    end
  end

  it 'starts from a stored report whose judged turns all lack a verdict: no failure, not evaluated, a warning and the cause in the judge of the turn' do
    cases = stored_report['cases']

    expect(cases.pluck('reasons')).to eq([[], []])
    expect(cases.pluck('status')).to eq(%w[not_evaluated not_evaluated])
    expect(cases.pluck('not_evaluated')).to eq([['judge'], ['judge']])
    expect(cases.pluck('judge')).to eq([{ 'unusable' => 'judge_unavailable', 'detail' => 'TypeError: no implicit conversion of nil into Hash' }] * 2)
    expect(cases.pluck('warnings')).to eq([['judge_unavailable']] * 2)
  end

  it 'judges those turns again with their rubric, the transcript and the facts of the workspace, and keeps the other failures' do
    report = stored_report
    report['cases'][1]['failures'] << { 'id' => 'empty_reply', 'check' => 'empty_reply', 'severity' => 'important', 'gate' => 'overall' }
    report['cases'][1]['reasons'] << 'empty_reply'
    stub_judge('{"pass":true,"reason":"ок"}')

    result = rejudge(report)
    first, second = result.report['cases']

    expect(result).to have_attributes(rejudged: 2, cost_usd: 0.0, stopped: nil)
    expect(first).to include('status' => 'pass', 'reasons' => [], 'failures' => [], 'warnings' => [], 'judge' => { 'pass' => true, 'reason' => 'ок' })
    expect(second).to include('status' => 'fail', 'reasons' => ['empty_reply'], 'warnings' => [], 'judge' => { 'pass' => true, 'reason' => 'ок' })
    expect([first, second]).to all(satisfy { |item| !item.key?('not_evaluated') })
    expect(second['evaluated']).not_to include('judge_unavailable')
    expect(prompts.size).to eq(2)
    expect(prompts.first).to include('Criterion of this turn: Здоровается и спрашивает, чем помочь.', 'Doctors: Терапевт Абдрахманова Сауле',
                                     'Q: Где вы находитесь? A: Центр, улица Абая 10.')
    expect(prompts.last).to include('Criterion of this turn: Называет адрес из базы знаний.',
                                    "Customer: Здравствуйте\nAgent: Здравствуйте! Чем помочь?\nCustomer: Подскажите адрес",
                                    'Reply to evaluate: Мы находимся в центре, улица Абая 10.')
    expect(prompts.last).not_to include('Ход 1')
  end

  it 'tells the judge how often the conversation was handed to staff in the turns before, as a live run does' do
    report = stored_report
    report['cases'][0]['handoff'] = { 'observed' => true, 'tool' => true }
    stub_judge('{"pass":true,"reason":"ок"}')

    rejudge(report)

    expect(prompts.first).to include('Handed to staff in this turn: yes (the handoff tool). Handed to staff in earlier turns of this dialogue: 0 time(s).')
    expect(prompts.last).to include('Handed to staff in this turn: no. Handed to staff in earlier turns of this dialogue: 1 time(s).')
  end

  it 'computes the aggregates, the triage list and the gate again from the new cases' do
    report = stored_report
    stub_judge('{"pass":true,"reason":"ок"}')

    result = rejudge(report).report

    expect(report['aggregates']).to include('passed' => 0, 'not_evaluated' => 2, 'judge_unusable' => { 'turns' => 2, 'by_check' => { 'judge_unavailable' => 2 } })
    expect(report['triage']).to be_empty
    expect(result['aggregates']).to include('total' => 2, 'passed' => 2, 'not_evaluated' => 0, 'judge_unusable' => { 'turns' => 0, 'by_check' => {} })
    expect(result['triage']).to be_empty
    expect(result['rejudge']).to eq('turns' => 2, 'cost_usd' => 0.0, 'all' => false)
  end

  it 'takes the turns off the list of the gate that wait for a verdict once every turn has it' do
    report = stored_report
    before = Captain::Evals::RoutingBenchmark::Gate.for_report(report)
    stub_judge('{"pass":true,"reason":"ок"}')

    after = rejudge(report).report['gate']

    expect(before).to include(not_evaluated: { turns: 2, by_check: { 'judge' => 2 } })
    expect(before[:blockers]).to include(a_string_starting_with('2 turn(s) not evaluated'))
    expect(after[:not_evaluated]).to eq(turns: 0, by_check: {})
    expect(after[:blockers]).not_to include(a_string_matching(/not evaluated/))
  end

  it 'keeps a turn not evaluated when the judge gives no verdict again' do
    report = stored_report
    stub_judge('not a verdict')

    result = rejudge(report).report

    expect(result['cases']).to all(include('status' => 'not_evaluated', 'not_evaluated' => ['judge']))
    expect(result['cases'].pluck('judge')).to all(include('unusable' => 'judge_invalid_json'))
    expect(result['gate'][:blockers]).to include(a_string_starting_with('2 turn(s) not evaluated'))
  end

  describe 'a report of an older run, which holds the missing verdict as a failure' do
    it 'is read without the failure by the gate, the triage list and the summary: the turns are not evaluated' do
      older = legacy_report
      gate = Captain::Evals::RoutingBenchmark::Gate.call(older['cases'])

      expect(gate[:overall]).to include(passed: 0, total: 0, not_evaluated: 2)
      expect(gate[:triage]).to include(failed_checks: 0)
      expect(Captain::Evals::RoutingBenchmark::Triage.records(older['cases'])).to be_empty
      expect(Captain::Evals::RoutingBenchmark::Summary.call(older['cases'])).to include(judge_unusable: { turns: 2, by_check: { 'judge_unavailable' => 2 } },
                                                                                         dialogues: include(passed: 0, failed: 0, not_evaluated: 1))
    end

    it 'is judged again, and the failure is gone' do
      older = legacy_report
      stub_judge('{"pass":true,"reason":"ок"}')

      result = rejudge(older)

      expect(result).to have_attributes(rejudged: 2)
      expect(result.report['cases']).to all(include('status' => 'pass', 'reasons' => [], 'failures' => [], 'warnings' => []))
    end
  end

  it 'turns a rejected reply into judge_failed' do
    report = stored_report
    stub_judge('{"pass":false,"reason":"слишком сухо"}')

    first = rejudge(report).report['cases'].first

    expect(first).to include('status' => 'fail', 'reasons' => ['judge_failed'], 'judge' => { 'pass' => false, 'reason' => 'слишком сухо' })
    expect(first['failures']).to contain_exactly(a_hash_including('id' => 'judge_failed', 'severity' => 'important'))
  end

  it 'leaves a turn that has its verdict alone unless every judged turn is asked for' do
    report = stored_report
    stub_judge('{"pass":true,"reason":"ок"}')
    judged = rejudge(report).report
    prompts.clear

    expect(rejudge(judged)).to have_attributes(rejudged: 0)
    expect(prompts).to be_empty
    expect(rejudge(judged, all: true)).to have_attributes(rejudged: 2)
    expect(prompts.size).to eq(2)
  end

  it 'stops at the budget and keeps the old case of a turn it did not judge' do
    report = stored_report
    stub_judge('{"pass":true,"reason":"ок"}', cost: 0.6)

    result = rejudge(report, budget_usd: 0.5)

    expect(result).to have_attributes(rejudged: 1, cost_usd: 0.6, stopped: 'budget_reached')
    expect(result.report['cases'].pluck('judge')).to eq(
      [{ 'pass' => true, 'reason' => 'ок' }, { 'unusable' => 'judge_unavailable', 'detail' => 'TypeError: no implicit conversion of nil into Hash' }]
    )
    expect(result.report['rejudge']).to include('turns' => 1, 'stopped' => 'budget_reached')
  end

  it 'refuses a fixture whose turn no longer matches the report, and a fixture file it cannot find' do
    report = stored_report
    stub_judge('{"pass":true,"reason":"ок"}')
    fixture_data[:dialogues].first[:turns].first[:customer] = 'Другой текст'
    File.write(fixture_path, fixture_data.deep_stringify_keys.to_yaml)

    expect { rejudge(report) }.to raise_error(ArgumentError, /no longer matches the report: case.yml judged turn 1/)
    expect { rejudge(report, fixture_paths: []) }.to raise_error(ArgumentError, %r{Fixture file not found: synthetic/case.yml})
  end

  describe 'captain:routing_benchmark_rejudge' do
    before { Rails.application.load_tasks unless Rake::Task.task_defined?('captain:routing_benchmark_rejudge') }

    it 'refuses an OUT that exists, before it touches anything' do
      out = File.join(dir, 'new.json')
      File.write(out, '{}')
      ENV['OUT'] = out
      Rake::Task['captain:routing_benchmark_rejudge'].reenable

      expect { Rake::Task['captain:routing_benchmark_rejudge'].invoke }.to raise_error(ArgumentError, 'OUT already exists')
    ensure
      ENV.delete('OUT')
    end
  end
end
