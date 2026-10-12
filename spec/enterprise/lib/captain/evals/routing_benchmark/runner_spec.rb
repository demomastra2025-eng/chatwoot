# frozen_string_literal: true

require 'rails_helper'
require 'tempfile'
require 'tmpdir'

RSpec.describe Captain::Evals::RoutingBenchmark::Runner do
  let(:fixture_data) do
    {
      workspace: {
        agents: [{ name: 'Регистратор', routing_description: 'Запись', instructions: 'Отвечай по-русски.',
                   tool_ids: %w[faq_lookup get_my_contact], model: 'openai/gpt-6-luna' }],
        contacts: [{ key: 'patient', name: 'Дана Нурланова' }]
      },
      dialogues: %w[first second third].map do |id|
        { id: id, contact: 'patient',
          turns: [{ customer: 'Здравствуйте', expect: { agent: 'Регистратор', council: false } }] }
      end
    }
  end
  let(:out) { Rails.root.join('tmp', "isolation-benchmark-#{SecureRandom.uuid}.json") }
  let(:seen) { [] }

  # The scripted runtime reports what the workspace holds when it is called, then leaves rows behind. A block that returns
  # a Hash adds its keys to the response of that turn ({ 'handoff_tool_called' => true }).
  def script_runtime(text: 'Здравствуйте!', **extra, &block)
    allow(Captain::Assistant::AgentRunnerService).to receive(:new) do |assistant:, conversation:, **|
      more = block.call(conversation)
      instance_double(Captain::Assistant::AgentRunnerService,
                      generate_response: { 'agent_id' => assistant.id, 'response' => text,
                                           'captain_request_id' => 'synthetic-request' }.merge(extra.stringify_keys).merge(more.is_a?(Hash) ? more : {}))
    end
  end

  def stub_fixture
    fixture = Captain::Evals::RoutingBenchmark::Fixture.new(fixture_data)
    allow(Captain::Evals::RoutingBenchmark::Guard).to receive(:check!).and_return(true)
    allow(Captain::Evals::RoutingBenchmark::Guard).to receive(:restrict_http!).and_return(true)
    allow(Dir).to receive(:glob).and_call_original
    allow(Dir).to receive(:glob).with('synthetic/*.yml').and_return(['synthetic/case.yml'])
    allow(Captain::Evals::RoutingBenchmark::Fixture).to receive(:load).and_return(fixture)
  end

  def run_benchmark(runs: 1, **options)
    runner = described_class.new(fixtures: 'synthetic/*.yml', runs: runs, budget_usd: 1, out: out, **options)
    allow(runner).to receive(:write_report)
    runner.call
  end

  it 'gives every dialogue a fresh workspace, so state never leaks from one dialogue to the next' do
    stub_fixture
    script_runtime do |conversation|
      seen << { account_id: conversation.account_id, contacts: Contact.where(account_id: conversation.account_id).pluck(:name) }
      Contact.create!(account: conversation.account, name: "Утекший контакт #{seen.size}")
      Contact.where(account_id: conversation.account_id, name: 'Дана Нурланова').update_all(name: 'Изменённый контакт')
    end

    report = run_benchmark

    expect(report.dig(:aggregates, :passed)).to eq(3)
    expect(seen.pluck(:account_id).uniq.size).to eq(3)
    expect(seen.pluck(:contacts)).to all(eq(['Дана Нурланова']))
  end

  it 'rolls every dialogue back, including across runs' do
    stub_fixture
    script_runtime { |conversation| seen << conversation.account_id }

    run_benchmark(runs: 2)

    expect(seen.uniq.size).to eq(6)
    expect(Account.where(id: seen)).to be_empty
  end

  it 'reports the isolation mode and the council aggregates' do
    stub_fixture
    script_runtime { |_conversation| nil }

    report = run_benchmark

    expect(report).to include(isolation: 'workspace_per_dialogue', warnings: [])
    expect(report[:aggregates]).to include(council_expected: 0, council_event_missing: 0, council_unexpected: 0,
                                           passed_ignoring_council_signal: 3, council_detection: 1.0)
  end

  it 'warns when turns expect a council and the runtime never emitted captain.council.started' do
    fixture_data[:dialogues].each { |dialogue| dialogue[:turns].first[:expect][:council] = true }
    stub_fixture
    script_runtime { |_conversation| nil }

    report = run_benchmark

    expect(report[:aggregates]).to include(council_expected: 3, council_event_missing: 3, passed: 0,
                                           passed_ignoring_council_signal: 3, routing_accuracy: 1.0)
    expect(report[:warnings].sole).to match(/council_event_missing: 3 of 3 .*captain\.council\.started/)
  end

  describe 'the release gate' do
    it 'comes first in the report, and a run that tests nothing with a booking or a person does not pass it, however clean' do
      stub_fixture
      script_runtime { |_conversation| nil }

      report = run_benchmark

      expect(report.keys.first(2)).to eq(%i[gate triage])
      expect(report[:gate]).to include(verdict: 'FAIL', blockers: ['item a not covered: no appointment operation is expected anywhere in this run',
                                                                   'item f not covered: no turn asks for a person'])
      expect(report[:gate][:overall]).to include(passed: 3, total: 3, pct: 100.0)
      expect(report[:triage]).to eq([])
    end

    it 'writes the JSON with the gate and triage first and a Markdown summary that starts with the gate' do
      stub_fixture
      script_runtime { |_conversation| nil }

      Dir.mktmpdir do |dir|
        path = File.join(dir, 'report.json')
        described_class.new(fixtures: 'synthetic/*.yml', runs: 1, budget_usd: 1, out: path).call

        expect(JSON.parse(File.read(path)).keys.first(2)).to eq(%w[gate triage])
        expect(File.read("#{path}.md")).to start_with("# Routing benchmark\n\n## GATE\n\n**Verdict: FAIL**")
      end
    end

    it 'fails a run that the budget cut short' do
      stub_fixture
      script_runtime { |_conversation| nil }
      runner = described_class.new(fixtures: 'synthetic/*.yml', runs: 1, budget_usd: 1, out: out)
      allow(runner).to receive(:write_report)
      allow(runner).to receive(:provider_cost).and_raise(described_class::BudgetExceeded, 'budget_reached')

      report = runner.call

      expect(report).to include(aborted: true)
      expect(report[:gate]).to include(verdict: 'FAIL', blockers: include('the run was cut short (budget_reached)'))
    end

    context 'with a booking that the agent made, and a customer who asks for a person' do
      let(:fixture_data) do
        {
          workspace: {
            agents: [{ name: 'Регистратор', routing_description: 'Запись', instructions: 'Отвечай по-русски.',
                       tool_ids: %w[faq_lookup create_appointment handoff], model: 'openai/gpt-6-luna' }],
            contacts: [{ key: 'patient', name: 'Дана Нурланова' }],
            resources: [{ key: 'doctor_a', name: 'Терапевт Абдрахманова Сауле' }, { key: 'doctor_b', name: 'Кардиолог Омаров Тимур' }],
            services: [{ key: 'consult', name: 'Консультация терапевта' }]
          },
          dialogues: [
            { id: 'booking', contact: 'patient', turns: [{
              customer: 'Запишите меня к терапевту на 12:00', at: '2026-10-12T09:00:00+05:00',
              expect: { agent: 'Регистратор', council: false, must_call: ['create_appointment'],
                        operations: [{ model: 'appointment', kind: 'create', resource: 'doctor_a', service: 'consult',
                                      starts_at: '2026-10-15T12:00:00+05:00', patient: 'patient' }] }
            }] },
            { id: 'person', contact: 'patient', turns: [{
              customer: 'позовите оператора', expect: { agent: 'Регистратор', council: false, human_request: true }
            }] }
          ]
        }
      end

      def asked_for_staff?(conversation)
        conversation.messages.where(message_type: :incoming).order(:id).last&.content.to_s.include?('оператор')
      end

      # The scripted answer: the booking with the given doctor, or the hand-over of a conversation in which a person was asked for.
      def answer(doctor_name)
        lambda do |conversation|
          next { 'handoff_tool_called' => true, 'response' => 'Передала вас администратору.' } if asked_for_staff?(conversation)

          book_with(doctor_name, conversation)
          nil
        end
      end

      def book_with(doctor_name, conversation)
        account = conversation.account
        starts_at = Time.iso8601('2026-10-15T12:00:00+05:00')
        Scheduling::Appointment.create!(
          account: account, resource: Scheduling::Resource.find_by!(account_id: account.id, name: doctor_name),
          service: Scheduling::Service.find_by!(account_id: account.id), contact: conversation.contact, client_name: conversation.contact.name,
          starts_at: starts_at, ends_at: starts_at + 30.minutes, duration_min: 30
        )
        LlmEvent.create!(account_id: account.id, event_name: 'llm.tool.complete', tool_name: 'create_appointment',
                         payload: { 'result_success' => true }, request_id: 'other-request')
        LlmEvent.create!(account_id: account.id, event_name: 'llm.chat.runtime_complete', request_id: 'other-request')
      end

      let(:reply) { 'Записала вас к терапевту на 15 октября в 12:00.' }

      it 'blocks the release with an operation_mismatch when the agent booked the wrong doctor, and lists the failure for triage' do
        stub_fixture
        script_runtime(text: reply, &answer('Кардиолог Омаров Тимур'))

        report = run_benchmark

        expect(report[:gate]).to include(verdict: 'FAIL')
        expect(report.dig(:gate, :critical, :failures)).to contain_exactly(
          a_hash_including(fixture: 'case.yml', dialogue: 'booking', turn: 1, check: 'operation_mismatch:resource', gate: 'a,c')
        )
        expect(report[:triage].sole).to include(
          'check' => 'operation_mismatch:resource', 'severity' => 'critical', 'patient_message' => 'Запишите меня к терапевту на 12:00',
          'agent_reply' => reply, 'acting_agent' => 'Регистратор', 'triage' => nil,
          'tool_calls' => [a_hash_including('tool' => 'create_appointment', 'success' => true)],
          'expectation' => a_hash_including('must_call' => ['create_appointment'])
        )
      end

      it 'reads the tool events of the whole turn and records what the turn did to the database' do
        stub_fixture
        script_runtime(text: reply, &answer('Кардиолог Омаров Тимур'))

        item = run_benchmark[:cases].find { |scored| scored[:dialogue] == 'booking' }

        expect(item).to include(tools: ['create_appointment'], llm_calls: 1, tool_steps: ['create_appointment:true:'], patient_text: reply)
        expect(item[:db_delta]).to contain_exactly(a_hash_including(change: 'created', resource: 'doctor_b', service: 'consult', patient: 'patient'))
        expect(item[:evaluated]).to include('operation_mismatch:resource', 'missing_operation:appointment', 'unexpected_mutation')
        expect(item[:evaluated]).not_to include('operation_mismatch')
      end

      it 'passes the run when the agent booked the right doctor and handed the person over: both gate items are put to the test' do
        stub_fixture
        script_runtime(text: reply, &answer('Терапевт Абдрахманова Сауле'))

        report = run_benchmark

        expect(report[:cases].pluck(:reasons)).to all(be_empty)
        expect(report[:gate]).to include(verdict: 'PASS', blockers: [])
        expect(report[:gate][:coverage]).to include('a' => { covered: 1, expected: 1 }, 'f' => { covered: 1 })
      end

      it 'keeps the raw verdict and reports the verdict after a person signed the failure as a test bug' do
        stub_fixture
        script_runtime(text: reply, &answer('Кардиолог Омаров Тимур'))
        labels = { Captain::Evals::RoutingBenchmark::Triage.key('case.yml', 'booking', 1, 'operation_mismatch:resource') => 'test_bug' }

        Tempfile.create(['labels', '.json']) do |file|
          file.write({ labels: labels }.to_json)
          file.flush
          report = run_benchmark(triage: file.path)

          expect(report[:gate]).to include(verdict: 'FAIL', after_triage: include(verdict: 'PASS'))
          expect(report[:triage].sole).to include('triage' => 'test_bug')
        end
      end
    end
  end

  describe 'the budget when the rubric judge runs' do
    let(:judge_cost) { 0.25 }

    # The judge writes a provider-response event of its own, as a real call does; the runner reads it back for the budget.
    def stub_judge
      cost = judge_cost
      allow(Llm::Runtime).to receive(:build_chat).and_return(Object.new)
      allow(Llm::Runtime).to receive(:ask) do |_chat, _prompt, account:, **|
        LlmEvent.create!(account_id: account.id, event_name: 'llm.chat.complete', model: described_class::MODEL, estimated_cost: cost,
                         payload: { 'usage_scope' => 'provider_response' }, request_id: 'judge-request')
        Struct.new(:content).new('{"pass":true,"reason":"ок"}')
      end
    end

    before do
      fixture_data[:dialogues].each { |dialogue| dialogue[:rubric] = 'Ответ вежливый.' }
      stub_fixture
      script_runtime { |_conversation| nil }
      stub_judge
    end

    it 'counts what the judge spent: its calls are provider spend of the turn' do
      report = run_benchmark(judge: true)

      expect(report[:cases].pluck(:judge)).to all(include(pass: true))
      expect(report[:cases].pluck(:cost_usd)).to eq([0.25, 0.25, 0.25])
      expect(report[:cost_usd]).to eq(0.75)
    end

    it 'stops the run at the budget when only the judge spends money' do
      runner = described_class.new(fixtures: 'synthetic/*.yml', runs: 1, budget_usd: 0.4, out: out, judge: true)
      allow(runner).to receive(:write_report)

      report = runner.call

      expect(report).to include(aborted: true, abort_reason: 'budget_reached', cost_usd: 0.5)
      expect(report[:cases].size).to eq(2)
    end
  end
end
