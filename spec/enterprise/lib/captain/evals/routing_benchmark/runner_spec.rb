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
  # The roles of the message history that each call of the runtime received.
  let(:histories) { [] }

  # The scripted runtime reports what the workspace holds when it is called, then leaves rows behind. A block that returns
  # a Hash adds its keys to the response of that turn ({ 'handoff_tool_called' => true }); a block with two parameters also gets
  # the entry agent.
  def script_runtime(text: 'Здравствуйте!', **extra, &block)
    allow(Captain::Assistant::AgentRunnerService).to receive(:new) do |assistant:, conversation:, **|
      more = block.arity == 2 ? block.call(conversation, assistant) : block.call(conversation)
      answer = { 'agent_id' => assistant.id, 'response' => text, 'captain_request_id' => 'synthetic-request' }
               .merge(extra.stringify_keys).merge(more.is_a?(Hash) ? more : {})
      instance_double(Captain::Assistant::AgentRunnerService).tap do |runner|
        allow(runner).to receive(:generate_response) do |message_history: []|
          histories << message_history.pluck(:role)
          answer
        end
      end
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
    expect(report[:warnings].first).to match(/council_event_missing: 3 of 3 .*captain\.council\.started/)
    expect(report[:warnings]).to include('council_expected_but_no_part_started: 3 turn(s)')
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

  describe 'what the runner does between the turns, as the response builder does' do
    let(:fixture_data) do
      {
        workspace: {
          agents: [{ name: 'Регистратор', routing_description: 'Запись', instructions: 'Отвечай по-русски.',
                     tool_ids: %w[faq_lookup get_my_contact], model: 'openai/gpt-6-luna' }],
          contacts: [{ key: 'patient', name: 'Дана Нурланова' }]
        },
        dialogues: [{ id: 'long', contact: 'patient', turns: [
          { customer: 'Позовите оператора', expect: { agent: 'Регистратор', council: false } },
          { customer: 'Алло', expect: { agent: 'Регистратор', council: false } },
          { customer: 'Спасибо', staff: { status: 'pending' }, expect: { agent: 'Регистратор', council: false } }
        ] }]
      }
    end

    def handoff_event(account, success: true)
      LlmEvent.create!(account_id: account.id, event_name: 'llm.tool.complete', tool_name: 'handoff', payload: { 'result_success' => success },
                       request_id: 'other-request')
    end

    # The first turn hands the conversation to staff the way the handoff tool does: the marker, the flag and a successful tool event.
    def hand_over_on_the_first_turn
      calls = 0
      script_runtime do |conversation|
        calls += 1
        seen << conversation.reload.status
        next unless calls == 1

        handoff_event(conversation.account)
        { 'response' => 'conversation_handoff', 'handoff_tool_called' => true }
      end
    end

    it 'leaves the conversation open for staff after an observed handoff, and gives it back to the AI on the turn that says pending' do
      stub_fixture
      hand_over_on_the_first_turn

      report = run_benchmark

      expect(seen).to eq(%w[pending open pending])
      expect(report[:cases].pluck(:warnings)).to eq([[], ['ai_answered_while_staff_owned'], []])
      expect(report[:warnings]).to include('ai_answered_while_staff_owned: 1 turn(s)')
    end

    # ResponseBuilderJob calls bot_handoff! on a failed turn as well: after the provider error response, after a technical failure of a tool
    # and after the technical handoff of a council part, the conversation is staff-owned, whether or not the handoff tool ran.
    provider_error = Captain::Assistant::AgentRunnerService::PROVIDER_ERROR_RESPONSE
    technical = { 'tool' => 'create_appointment', 'stage' => 'execution', 'reason' => 'provider_timeout', 'kind' => 'technical' }
    {
      'the provider error response' => { 'response' => provider_error },
      'a technical failure of a tool' => { 'response' => provider_error, 'technical_failure' => technical },
      'the technical handoff of a council part' => { 'council_handoff' => { 'reason' => 'council_unresolved', 'technical' => true,
                                                                             'failures' => [technical] } },
      'the council handoff of an unresolved part' => { 'council_handoff' => { 'reason' => 'council_unresolved', 'parts' => ['результаты'] } }
    }.each do |name, first_turn|
      it "leaves the conversation open for staff after #{name}, and warns when the next turn is answered without staff giving it back" do
        stub_fixture
        calls = 0
        script_runtime do |conversation|
          calls += 1
          seen << conversation.reload.status
          first_turn if calls == 1
        end

        report = run_benchmark

        expect(seen).to eq(%w[pending open pending])
        warned = report[:cases].map { |item| item[:warnings].include?('ai_answered_while_staff_owned') }
        expect(warned).to eq([false, true, false])
      end
    end

    it 'leaves the conversation as it is after an ordinary reply' do
      stub_fixture
      script_runtime { |conversation| seen << conversation.reload.status }

      run_benchmark

      expect(seen).to eq(%w[pending pending pending])
    end

    it 'does not hand the conversation over for a marker with no handoff tool event, or a failed handoff' do
      stub_fixture
      calls = 0
      script_runtime do |conversation|
        calls += 1
        seen << conversation.reload.status
        handoff_event(conversation.account, success: false) if calls == 1
        { 'response' => 'conversation_handoff', 'handoff_tool_called' => true } if calls <= 2
      end

      report = run_benchmark

      expect(seen).to eq(%w[pending pending pending])
      expect(report[:cases].pluck(:warnings)).to eq([['handoff_marker_without_tool'], ['handoff_marker_without_tool'], []])
    end

    it 'gives the model the replies the customer saw and nothing else: no handoff marker, no provider error, no suppressed reply' do
      stub_fixture
      calls = 0
      script_runtime do |_conversation|
        calls += 1
        case calls
        when 1 then { 'response' => 'conversation_handoff', 'handoff_tool_called' => true }
        when 2 then { 'response' => Captain::Assistant::AgentRunnerService::PROVIDER_ERROR_RESPONSE }
        end
      end

      run_benchmark

      expect(histories).to eq([%w[user], %w[user user], %w[user user user]])
    end

    it 'keeps the replies, and leaves out a suppressed one' do
      stub_fixture
      calls = 0
      script_runtime do |_conversation|
        calls += 1
        { 'response' => '', 'response_mode' => 'suppress' } if calls == 2
      end

      run_benchmark

      expect(histories).to eq([%w[user], %w[user assistant user], %w[user assistant user user]])
    end

    it 'records the reply as delivered with every part it reports, so the next turn does not announce the booking again' do
      stub_fixture
      calls = 0
      parts = nil
      script_runtime do |conversation, assistant|
        calls += 1
        session = Captain::Conversation::AgentSession.new(entry: assistant, conversation: conversation)
        if calls == 1
          session.change { |data| data['parts'] = [{ 'id' => 'p1', 'version' => 1, 'state' => 'done', 'acted' => true, 'delivered' => [] }] }
          { 'part_refs' => [{ 'id' => 'p1', 'version' => 1 }, { 'id' => 'gone', 'version' => 1 }] }
        elsif calls == 2
          parts = session.read['parts']
          nil
        end
      end

      run_benchmark

      expect(parts.first['delivered']).to contain_exactly(a_hash_including('content' => 'Здравствуйте!', 'version' => 1, 'message_id' => be_negative))
    end

    it 'records no delivery for a reply the customer did not read' do
      stub_fixture
      calls = 0
      parts = nil
      script_runtime do |conversation, assistant|
        calls += 1
        session = Captain::Conversation::AgentSession.new(entry: assistant, conversation: conversation)
        if calls == 1
          session.change { |data| data['parts'] = [{ 'id' => 'p1', 'version' => 1, 'state' => 'done', 'acted' => true, 'delivered' => [] }] }
          { 'response' => 'conversation_handoff', 'handoff_tool_called' => true, 'part_refs' => [{ 'id' => 'p1', 'version' => 1 }] }
        elsif calls == 2
          parts = session.read['parts']
          nil
        end
      end

      run_benchmark

      expect(parts.first['delivered']).to be_empty
    end

    it 'hands the scorer the routing of the session before and after the turn, and fails a council turn that changed hands' do
      fixture_data[:dialogues] = [{ id: 'council', contact: 'patient', turns: [{ customer: 'Здравствуйте', expect: { agent: 'Регистратор', council: true } }] }]
      stub_fixture
      script_runtime do |conversation, assistant|
        LlmEvent.create!(account_id: conversation.account_id, event_name: 'captain.council.started', request_id: 'other-request', payload: {})
        conversation.update_column(:additional_attributes, { 'captain_agent_session' => { 'current_assistant_id' => assistant.id + 1000, 'routing_revision' => 1 } })
        nil
      end

      item = run_benchmark[:cases].sole

      expect(item[:reasons]).to eq(['council_changed_hands'])
      expect(item[:routing][:before]).to include(routing_revision: 0)
      expect(item[:routing][:after]).to include(routing_revision: 1)
      expect(item[:routing][:after][:current_assistant_id]).not_to eq(item[:routing][:before][:current_assistant_id])
    end

    it 'proves that the handoff is silent, and blocks the gate when the notice of the synthetic account is not blank' do
      stub_fixture
      script_runtime { |_conversation| nil }

      expect(run_benchmark).to include(silent_handoff: true)

      notice = instance_double(Captain::CustomerNoticeService, text: 'Сотрудник продолжит диалог с вами.')
      allow(Captain::CustomerNoticeService).to receive(:new).and_return(notice)
      report = run_benchmark

      expect(report).to include(silent_handoff: false)
      expect(report[:gate][:blockers]).to include(a_string_starting_with('the handoff notice of the synthetic account is not blank'))
      expect(report[:warnings]).to include('the handoff notice of the synthetic account is not blank: a handoff is not silent')
    end

    it 'blocks the gate when the notice of the synthetic account cannot be read: silent handoff is not proven, nor the text of a handoff turn' do
      stub_fixture
      script_runtime { |_conversation| nil }
      allow(Captain::CustomerNoticeService).to receive(:new).and_raise(ActiveRecord::StatementInvalid, 'connection lost')

      report = run_benchmark

      expect(report).to include(silent_handoff_error: 'ActiveRecord::StatementInvalid')
      expect(report).not_to have_key(:silent_handoff)
      expect(report[:gate]).to include(verdict: 'FAIL', silent_handoff_error: 'ActiveRecord::StatementInvalid')
      expect(report[:gate][:blockers]).to include('silent handoff not proven: the notice could not be read (ActiveRecord::StatementInvalid); ' \
                                                  'the text of a handoff turn is not checked')
      expect(report[:warnings]).to include(a_string_starting_with('the handoff notice could not be checked (ActiveRecord::StatementInvalid)'))
    end

    it 'counts the model calls of the turn by runtime_complete events, else by requests, and never by the provider responses' do
      stub_fixture
      calls = 0
      script_runtime do |conversation|
        calls += 1
        account_id = conversation.account_id
        if calls == 1
          2.times { LlmEvent.create!(account_id: account_id, event_name: 'llm.chat.runtime_complete', request_id: 'other-request') }
        elsif calls == 2
          3.times { LlmEvent.create!(account_id: account_id, event_name: 'llm.chat.request', request_id: 'other-request') }
          LlmEvent.create!(account_id: account_id, event_name: 'llm.chat.complete', model: described_class::MODEL, estimated_cost: 0,
                           payload: { 'usage_scope' => 'provider_response' }, request_id: 'other-request')
        end
        nil
      end

      expect(run_benchmark[:cases].pluck(:llm_calls)).to eq([2, 3, 0])
    end

    it 'reports the agent and the part of every tool call, from the assistant id of the monitoring event' do
      stub_fixture
      script_runtime do |conversation, assistant|
        LlmEvent.create!(account_id: conversation.account_id, assistant_id: assistant.id, event_name: 'llm.tool.complete', tool_name: 'faq_lookup',
                         payload: { 'result_success' => true, 'part_id' => 'abcdef123456' }, request_id: 'other-request')
        nil
      end

      expect(run_benchmark[:cases].first[:tool_calls]).to eq([{ tool: 'faq_lookup', success: true, audited: false, agent: 'Регистратор', part_id: 'abcdef12' }])
    end

    it 'sums the turns up per dialogue, per category and per reason, and keeps the dialogue summaries after the cases' do
      fixture_data[:dialogues] = [{ id: 'plain_01', contact: 'patient', turns: [
        { customer: 'Здравствуйте', expect: { agent: 'Регистратор', council: false } },
        { customer: 'Спасибо', expect: { agent: 'Регистратор', council: false } }
      ] }]
      stub_fixture
      script_runtime(text: 'Пожалуйста, обращайтесь.') { |_conversation| nil }

      report = run_benchmark

      expect(report[:aggregates]).to include(dialogues: include(total: 1, passed: 1, pass_k: include(k: 1, rate: 1.0)), by_category: { 'plain' => include(dialogues: 1) },
                                             by_reason: {}, infra: { turns: 0, by_check: {} }, routing_accuracy: 1.0)
      expect(report[:dialogue_summaries]).to contain_exactly(a_hash_including(dialogue: 'plain_01', pass: true, statuses: %w[pass pass]))
    end
  end

  describe 'the rubric judge' do
    let(:prompts) { [] }
    let(:verdict) { '{"pass":true,"reason":"ок"}' }
    let(:fixture_data) do
      {
        workspace: {
          agents: [{ name: 'Регистратор', routing_description: 'Запись', instructions: 'Отвечай по-русски.', tool_ids: %w[faq_lookup handoff], model: 'openai/gpt-6-luna' }],
          contacts: [{ key: 'patient', name: 'Дана Нурланова' }],
          resources: [{ key: 'doctor_a', name: 'Терапевт Абдрахманова Сауле' }],
          services: [{ key: 'consult', name: 'Консультация терапевта', duration_min: 30, base_price: 7000 }],
          knowledge: [{ question: 'Где вы находитесь?', answer: 'Центр, улица Абая 10.' }]
        },
        dialogues: [{ id: 'judged', contact: 'patient',
                      rubric: 'Пациент — Дана Нурланова (сама). Во всех ответах: по-русски. Ход 1: Здоровается. Ход 2: Молча передаёт сотруднику.',
                      turns: [{ customer: 'Здравствуйте', rubric: 'Здоровается и спрашивает, чем помочь.', expect: { agent: 'Регистратор', council: false } },
                              { customer: 'позовите оператора', rubric: 'Молча передаёт сотруднику.', expect: { agent: 'Регистратор', council: false } }] }]
      }
    end

    def stub_judge(content)
      allow(Llm::Runtime).to receive(:build_chat).and_return(Object.new)
      allow(Llm::Runtime).to receive(:ask) do |_chat, prompt, account:, **|
        prompts << prompt
        LlmEvent.create!(account_id: account.id, event_name: 'llm.chat.complete', model: described_class::MODEL, estimated_cost: 0,
                         payload: { 'usage_scope' => 'provider_response' }, request_id: 'judge-request')
        Struct.new(:content).new(content)
      end
    end

    def hand_over_on_the_second_turn
      calls = 0
      script_runtime do |conversation|
        calls += 1
        next unless calls == 2

        LlmEvent.create!(account_id: conversation.account_id, event_name: 'llm.tool.complete', tool_name: 'handoff', payload: { 'result_success' => true },
                         request_id: 'other-request')
        { 'response' => 'conversation_handoff', 'handoff_tool_called' => true }
      end
    end

    before { hand_over_on_the_second_turn }

    it 'judges the reply against the rubric of the turn, with the header of the dialogue, the transcript, the tool calls and the facts of the workspace' do
      stub_fixture
      stub_judge(verdict)

      run_benchmark(judge: true)

      prompt = prompts.first
      expect(prompt).to include('Criterion of this turn: Здоровается и спрашивает, чем помочь.',
                                'Context of the dialogue: Пациент — Дана Нурланова (сама). Во всех ответах: по-русски.',
                                'Doctors: Терапевт Абдрахманова Сауле', 'Консультация терапевта 7000 KZT, 30 min', 'Q: Где вы находитесь? A: Центр, улица Абая 10.',
                                'Customer message: Здравствуйте', 'Reply to evaluate: Здравствуйте!')
      expect(prompt).not_to include('Ход 1', 'Молча передаёт')
    end

    it 'does not judge a silent handoff or a runtime marker: there is nothing to read' do
      stub_fixture
      stub_judge(verdict)

      report = run_benchmark(judge: true)

      expect(prompts.size).to eq(1)
      expect(report[:cases].pluck(:judge)).to eq([{ pass: true, reason: 'ок' }, nil])
    end

    it 'tolerates a fence around the verdict' do
      stub_fixture
      stub_judge("```json\n{\"pass\":false,\"reason\":\"слишком сухо\"}\n```")

      item = run_benchmark(judge: true)[:cases].first

      expect(item[:reasons]).to eq(['judge_failed'])
      expect(item[:judge]).to eq(pass: false, reason: 'слишком сухо')
    end

    it 'can only add a failure: a pass of the judge removes none of the deterministic ones' do
      fixture_data[:dialogues].first[:turns].first[:expect][:agent] = 'Другой агент'
      fixture_data[:workspace][:agents] << { name: 'Другой агент', routing_description: 'Другое', instructions: 'Отвечай.', tool_ids: %w[faq_lookup] }
      stub_fixture
      stub_judge(verdict)

      item = run_benchmark(judge: true)[:cases].first

      expect(item[:reasons]).to eq(['wrong_agent'])
      expect(item[:judge]).to include(pass: true)
    end

    it 'reports an answer it cannot read as a minor failure' do
      stub_fixture
      stub_judge('не знаю')

      expect(run_benchmark(judge: true)[:cases].first[:failures]).to contain_exactly(a_hash_including(id: 'judge_invalid_json', severity: 'minor'))
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
