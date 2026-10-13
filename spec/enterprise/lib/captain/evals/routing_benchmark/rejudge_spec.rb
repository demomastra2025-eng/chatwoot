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
    allow(runner).to receive(:write_report)
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

  it 'starts from a stored report whose judged turns all lack a verdict' do
    cases = stored_report['cases']

    expect(cases.pluck('reasons')).to eq([['judge_unavailable'], ['judge_unavailable']])
    expect(cases.dig(0, 'failures', 0)).to include('check' => 'judge_unavailable', 'detail' => 'TypeError')
  end

  it 'judges those turns again with their rubric, the transcript and the facts of the workspace, and keeps the other failures' do
    report = stored_report
    report['cases'][1]['failures'] << { 'id' => 'wrong_language', 'check' => 'wrong_language', 'severity' => 'important', 'gate' => 'overall' }
    report['cases'][1]['reasons'] << 'wrong_language'
    stub_judge('{"pass":true,"reason":"ок"}')

    result = rejudge(report)
    first, second = result.report['cases']

    expect(result).to have_attributes(rejudged: 2, cost_usd: 0.0, stopped: nil)
    expect(first).to include('status' => 'pass', 'reasons' => [], 'failures' => [], 'judge' => { 'pass' => true, 'reason' => 'ок' })
    expect(second).to include('status' => 'fail', 'reasons' => ['wrong_language'], 'judge' => { 'pass' => true, 'reason' => 'ок' })
    expect(second['evaluated']).not_to include('judge_unavailable')
    expect(prompts.size).to eq(2)
    expect(prompts.first).to include('Criterion of this turn: Здоровается и спрашивает, чем помочь.', 'Doctors: Терапевт Абдрахманова Сауле',
                                     'Q: Где вы находитесь? A: Центр, улица Абая 10.')
    expect(prompts.last).to include('Criterion of this turn: Называет адрес из базы знаний.',
                                    "Customer: Здравствуйте\nAgent: Здравствуйте! Чем помочь?\nCustomer: Подскажите адрес",
                                    'Reply to evaluate: Мы находимся в центре, улица Абая 10.')
    expect(prompts.last).not_to include('Ход 1')
  end

  it 'computes the aggregates, the triage list and the gate again from the new cases' do
    report = stored_report
    stub_judge('{"pass":true,"reason":"ок"}')

    result = rejudge(report).report

    expect(report['aggregates']['passed']).to eq(0)
    expect(report['triage'].pluck('check')).to include('judge_unavailable')
    expect(result['aggregates']).to include('total' => 2, 'passed' => 2)
    expect(result['triage'].pluck('check')).not_to include('judge_unavailable')
    expect(result['rejudge']).to eq('turns' => 2, 'cost_usd' => 0.0, 'all' => false)
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
    expect(result.report['cases'].pluck('reasons')).to eq([[], ['judge_unavailable']])
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
