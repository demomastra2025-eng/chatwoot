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

  def report_file(dir, name, cases)
    path = File.join(dir, name)
    aggregates = { 'total' => cases.size, 'passed' => cases.count { |item| item['reasons'].empty? }, 'hard_zero' => {} }
    File.write(path, JSON.generate('model' => 'openai/gpt-6-luna', 'runs' => 1, 'aborted' => false, 'cases' => cases, 'aggregates' => aggregates))
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

  let(:clean) { Array.new(100) { |index| turn("d#{index}") } }

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
