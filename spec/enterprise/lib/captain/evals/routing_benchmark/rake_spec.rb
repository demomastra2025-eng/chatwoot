# frozen_string_literal: true

require 'rails_helper'
require 'rake'
require 'tmpdir'

RSpec.describe 'routing benchmark rake tasks' do
  before do
    Rails.application.load_tasks unless Rake::Task.task_defined?('captain:routing_benchmark_compare')
  end

  def turn(dialogue, reasons = [])
    { 'fixture' => '/set/ws_a.yml', 'dialogue' => dialogue, 'run' => 1, 'turn' => 1, 'status' => reasons.empty? ? 'pass' : 'fail',
      'reasons' => reasons, 'customer' => 'Здравствуйте', 'reply' => 'Здравствуйте!' }
  end

  def report_file(dir, name, cases, **extra)
    path = File.join(dir, name)
    aggregates = { 'total' => cases.size, 'passed' => cases.count { |item| item['reasons'].empty? }, 'hard_zero' => {} }
    File.write(path, JSON.generate({ 'model' => 'openai/gpt-6-luna', 'runs' => 1, 'aborted' => false, 'cases' => cases, 'aggregates' => aggregates }
                                   .merge(extra.stringify_keys)))
    path
  end

  # Runs a task with ENV set; returns what it printed and the exit status it asked for (nil when it did not exit).
  def run_task(name, **env)
    stdout = StringIO.new
    status = nil
    original = $stdout
    $stdout = stdout
    env.each { |key, value| ENV[key.to_s] = value }
    begin
      Rake::Task[name].reenable
      Rake::Task[name].invoke
    rescue SystemExit => e
      status = e.status
    ensure
      $stdout = original
      env.each_key { |key| ENV.delete(key.to_s) }
    end
    [stdout.string, status]
  end

  # 100 clean turns; the first puts gate items a (a booking with its doctor, time and service) and f (a request for a person) to the test.
  let(:clean) do
    Array.new(100) { |index| turn("d#{index}") }.tap do |list|
      booking = { 'model' => 'appointment', 'kind' => 'create', 'resource' => 'doctor_a', 'service' => 'consult', 'starts_at' => '2026-10-15T12:00:00+05:00' }
      list[0] = list[0].merge('expectation' => { 'operations' => [booking] }, 'human_request' => { 'value' => true, 'source' => 'fixture' })
    end
  end

  describe 'captain:routing_benchmark_fixtures' do
    def write_fixture(dir, operations:, customer: 'позовите оператора', expectation: { 'staff_handoff' => true }, **extra)
      turn = ->(text, expect) { { 'customer' => text, 'expect' => { 'agent' => 'Регистратор', 'council' => false }.merge(expect) } }
      data = {
        'workspace' => {
          'agents' => [{ 'name' => 'Регистратор', 'routing_description' => 'Запись', 'instructions' => 'Отвечай.', 'tool_ids' => %w[faq_lookup] }],
          'contacts' => [{ 'key' => 'patient', 'name' => 'Дана Нурланова' }], 'resources' => [{ 'key' => 'doctor_a', 'name' => 'Терапевт Иванов Иван' }],
          'services' => [{ 'key' => 'consult', 'name' => 'Консультация' }]
        }.merge(extra.stringify_keys),
        'dialogues' => [{ 'id' => 'd1', 'contact' => 'patient',
                          'turns' => [turn.call('Запишите меня', 'operations' => operations), turn.call(customer, expectation)] }]
      }
      File.write(File.join(dir, 'ws_a.yml'), data.to_yaml)
    end

    let(:booking) do
      { 'model' => 'appointment', 'kind' => 'create', 'params' => { 'status' => 'scheduled', 'starts_at' => '2026-10-15T12:00:00+05:00' } }
    end

    it 'names the fixture that the strict loader refuses for an operation without a start, and exits with 1' do
      Dir.mktmpdir do |dir|
        write_fixture(dir, operations: [{ 'model' => 'appointment', 'kind' => 'create', 'count' => 1, 'resource' => 'doctor_a' }], expectation: {})

        output, status = run_task('captain:routing_benchmark_fixtures', FIXTURES: File.join(dir, '*.yml'))

        expect(output).to include('Invalid fixture: ws_a.yml: An appointment operation must pin params.starts_at')
        expect(status).to eq(1)
      end
    end

    it 'prints the gaps of a fixture that loads, and exits with 1' do
      Dir.mktmpdir do |dir|
        write_fixture(dir, operations: [booking], expectation: {})

        output, status = run_task('captain:routing_benchmark_fixtures', FIXTURES: File.join(dir, '*.yml'))

        expect(output).to include('Ready for the gate: no.', '- ws_a.yml d1 turn 2: the customer asks for a person: add staff_handoff: true')
        expect(status).to eq(1)
      end
    end

    it 'names the file and the key the strict loader refuses' do
      Dir.mktmpdir do |dir|
        write_fixture(dir, operations: [booking], appointmens: [])

        output, status = run_task('captain:routing_benchmark_fixtures', FIXTURES: File.join(dir, '*.yml'))

        expect(output).to include('Invalid fixture: ws_a.yml: Unknown key in workspace: appointmens')
        expect(status).to eq(1)
      end
    end

    it 'prints what the calendar lint found' do
      Dir.mktmpdir do |dir|
        slots = [{ 'resource' => 'doctor_a', 'weekday' => 4, 'start_minute' => 540, 'end_minute' => 600 }]
        write_fixture(dir, operations: [booking], slots: slots)

        output, status = run_task('captain:routing_benchmark_fixtures', FIXTURES: File.join(dir, '*.yml'))

        expect(output).to include('Ready for the gate: no.', '- ws_a.yml d1 turn 1: 2026-10-15T12:00:00+05:00 (30 min) is not possible for doctor_a: outside the work window (09:00-10:00)')
        expect(status).to eq(1)
      end
    end

    it 'exits quietly for fixtures that are ready for the gate' do
      Dir.mktmpdir do |dir|
        write_fixture(dir, operations: [booking])

        output, status = run_task('captain:routing_benchmark_fixtures', FIXTURES: File.join(dir, '*.yml'))

        expect(output).to include('Ready for the gate: yes.')
        expect(status).to be_nil
      end
    end
  end

  describe 'captain:routing_benchmark' do
    let(:runner) { instance_double(Captain::Evals::RoutingBenchmark::Runner, call: {}) }

    around do |example|
      saved = ENV.fetch('CAPTAIN_COUNCIL_PARALLEL', nil)
      example.run
    ensure
      saved.nil? ? ENV.delete('CAPTAIN_COUNCIL_PARALLEL') : ENV['CAPTAIN_COUNCIL_PARALLEL'] = saved
    end

    before do
      allow(Captain::Evals::RoutingBenchmark::Runner).to receive(:new).and_return(runner)
      allow(Llm::EventSubscriber).to receive(:install!)
      pool = ActiveRecord::Base.connection_pool
      allow(pool).to receive(:pin_connection!)
      allow(pool).to receive(:unpin_connection!)
    end

    it 'runs the parts of a council one after another on the calling thread: a thread on the pinned connection would deadlock' do
      ENV.delete('CAPTAIN_COUNCIL_PARALLEL')

      run_task('captain:routing_benchmark', FIXTURES: 'tmp/x/*.yml', BUDGET_USD: '1', OUT: 'tmp/x.json')

      expect(ENV.fetch('CAPTAIN_COUNCIL_PARALLEL')).to eq('off')
      expect(runner).to have_received(:call)
    end

    it 'gives the runner the standard output for its progress lines: one per dialogue, while the run goes' do
      run_task('captain:routing_benchmark', FIXTURES: 'tmp/x/*.yml', BUDGET_USD: '1', OUT: 'tmp/x.json')

      # run_task stands a StringIO in for the standard output of the task
      expect(Captain::Evals::RoutingBenchmark::Runner).to have_received(:new).with(hash_including(progress: an_instance_of(StringIO)))
    end

    it 'leaves a switch that somebody set on purpose alone' do
      ENV['CAPTAIN_COUNCIL_PARALLEL'] = 'on'

      run_task('captain:routing_benchmark', FIXTURES: 'tmp/x/*.yml', BUDGET_USD: '1', OUT: 'tmp/x.json')

      expect(ENV.fetch('CAPTAIN_COUNCIL_PARALLEL')).to eq('on')
    end
  end

  describe 'captain:routing_benchmark_compare' do
    it 'prints the comparison and exits quietly for two similar runs' do
      Dir.mktmpdir do |dir|
        first = report_file(dir, 'first.json', clean)
        second = report_file(dir, 'second.json', clean)

        output, status = run_task('captain:routing_benchmark_compare', FIRST: first, SECOND: second)

        expect(output).to start_with("# Benchmark comparison\n\n**Similar: yes**")
        expect(status).to be_nil
      end
    end

    it 'exits with 1 when the second run has a critical failure the first did not, and writes the comparison to OUT' do
      Dir.mktmpdir do |dir|
        first = report_file(dir, 'first.json', clean)
        second = report_file(dir, 'second.json', [turn('d0', ['false_success_claim'])] + clean.drop(1))
        out = File.join(dir, 'comparison.json')

        output, status = run_task('captain:routing_benchmark_compare', FIRST: first, SECOND: second, OUT: out)

        expect(output).to include('**Similar: no**', 'New in the second run: ws_a.yml/d0/run1/t1 false_success_claim')
        expect(status).to eq(1)
        expect(JSON.parse(File.read(out))).to include('similar' => false)
        expect(File.read("#{out}.md")).to start_with('# Benchmark comparison')
      end
    end

    it 'exits with 1 for two similar runs that both fail the gate: the same critical failure twice is no pass of gate item 3' do
      Dir.mktmpdir do |dir|
        failing = clean.each_with_index.map { |item, index| index == 5 ? turn('d5', ['false_success_claim']) : item }
        first = report_file(dir, 'first.json', failing)
        second = report_file(dir, 'second.json', failing)

        output, status = run_task('captain:routing_benchmark_compare', FIRST: first, SECOND: second)

        expect(output).to include('**Similar: yes**', 'Both runs pass the gate: no', 'Gate item 3 (two consecutive runs, similar and both passing): FAIL')
        expect(status).to eq(1)
      end
    end

    it 'does not overwrite an OUT file' do
      Dir.mktmpdir do |dir|
        first = report_file(dir, 'first.json', clean)
        out = File.join(dir, 'comparison.json')
        File.write(out, '{}')

        expect { run_task('captain:routing_benchmark_compare', FIRST: first, SECOND: first, OUT: out) }.to raise_error(ArgumentError, 'OUT already exists')
      end
    end
  end

  describe 'captain:routing_benchmark_gate' do
    it 'prints the gate of a clean output as PASS' do
      Dir.mktmpdir do |dir|
        output, status = run_task('captain:routing_benchmark_gate', REPORT: report_file(dir, 'clean.json', clean))

        expect(output).to include('## GATE', '**Verdict: PASS**', '## TRIAGE', '0 failed check(s).')
        expect(status).to be_nil
      end
    end

    it 'blocks a report whose handoff notice the runner could not read: silent handoff is not proven' do
      Dir.mktmpdir do |dir|
        path = report_file(dir, 'unproven.json', clean, silent_handoff_error: 'Timeout::Error')
        output, status = run_task('captain:routing_benchmark_gate', REPORT: path)

        expect(output).to include('**Verdict: FAIL**', '- silent handoff not proven: the notice could not be read (Timeout::Error)',
                                  '| Handoff is silent (blank notice) | not proven: Timeout::Error |')
        expect(status).to eq(1)
      end
    end

    it 'prints the gate and the triage list of an older output, and exits with 1 on FAIL' do
      Dir.mktmpdir do |dir|
        failing = [turn('risky', ['forbidden_tool:create_appointment', 'wrong_agent'])] + clean
        output, status = run_task('captain:routing_benchmark_gate', REPORT: report_file(dir, 'old.json', failing))

        expect(output).to include('**Verdict: FAIL**', '- `risky` turn 1: `forbidden_tool:create_appointment` (gate a,c)',
                                  '### 1. critical - `risky` turn 1 - `forbidden_tool:create_appointment`')
        expect(status).to eq(1)
      end
    end

    it 'applies the decisions of a triage file' do
      Dir.mktmpdir do |dir|
        failing = [turn('risky', ['forbidden_tool:create_appointment'])] + clean
        labels = File.join(dir, 'labels.json')
        key = Captain::Evals::RoutingBenchmark::Triage.key('ws_a.yml', 'risky', 1, 'forbidden_tool:create_appointment')
        File.write(labels, JSON.generate('labels' => { key => 'test_bug' }))

        output, = run_task('captain:routing_benchmark_gate', REPORT: report_file(dir, 'old.json', failing), TRIAGE: labels)

        expect(output).to include('**Verdict: FAIL**', 'After triage (test bugs and judge errors removed): **PASS**', '- Triage: test_bug')
      end
    end
  end
end
