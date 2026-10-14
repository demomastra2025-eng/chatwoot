# frozen_string_literal: true

require 'rails_helper'
require 'tempfile'
require 'tmpdir'

RSpec.describe Captain::Evals::RoutingBenchmark::Runner do
  it 'passes council part tool results to the judge beyond the report preview length' do
    call = { tool: 'search_available_slots', success: true, part_id: 'part-1', result: 'free at 09:00 ' * 40 }

    result = described_class.allocate.send(:judge_tool_results, [call]).first

    expect(result[:result].length).to be > Captain::Evals::RoutingBenchmark::ToolTrace::MAX_RESULT
    expect(result[:part_id]).to eq('part-1')
  end

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

  # The embedding of a FAQ answer of the workspace is a call to the embedding provider.
  before { allow(Captain::Llm::UpdateEmbeddingJob).to receive(:perform_now) }

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

  # The pause before a judge call is asked again is not waited for; the block gets the runner to look at the pauses.
  def run_benchmark(runs: 1, **options)
    runner = described_class.new(fixtures: 'synthetic/*.yml', runs: runs, budget_usd: 1, out: out, **options)
    allow(runner).to receive(:write_report)
    allow(runner).to receive(:judge_pause)
    yield runner if block_given?
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

  it 'records the language the runtime decided on for each turn, beside the reply' do
    stub_fixture
    script_runtime(text: 'Дайын.', patient_language: 'Kazakh') { |_conversation| nil }

    report = run_benchmark

    expect(report[:cases].map { |item| item.dig(:response_flags, :patient_language) }).to all(eq('Kazakh'))
    expect(report[:cases].first[:response_keys]).to include('patient_language')
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

  describe 'the progress lines' do
    let(:progress) { StringIO.new }

    def lines = progress.string.lines.map(&:chomp)

    it 'prints one line after every dialogue and flushes it at once, so a long run can be followed' do
      stub_fixture
      script_runtime { |_conversation| nil }
      allow(progress).to receive(:flush).and_call_original

      run_benchmark(progress: progress)

      expect(lines).to eq(['[1/3] first turns passed 1/1, not evaluated 0, critical 0, hints 0 (critical 0), reasons: none', '[2/3] second turns passed 1/1, not evaluated 0, critical 0, hints 0 (critical 0), reasons: none',
                           '[3/3] third turns passed 1/1, not evaluated 0, critical 0, hints 0 (critical 0), reasons: none'])
      expect(progress).to have_received(:flush).exactly(3).times
    end

    it 'counts the dialogues of all the runs, and names the turns that passed, the critical failures and the reasons of a dialogue that did not pass' do
      fixture_data[:dialogues] = fixture_data[:dialogues].first(1)
      fixture_data[:dialogues].first[:turns] = [{ customer: 'Здравствуйте', expect: { agent: 'Регистратор', council: true } },
                                                { customer: 'Спасибо', expect: { agent: 'Регистратор', council: false } }]
      stub_fixture
      script_runtime(text: 'Пожалуйста, обращайтесь.') { |_conversation| nil }

      run_benchmark(runs: 2, progress: progress)

      expect(lines).to eq(['[1/2] first turns passed 1/2, not evaluated 0, critical 0, hints 0 (critical 0), reasons: council_event_missing',
                           '[2/2] first turns passed 1/2, not evaluated 0, critical 0, hints 0 (critical 0), reasons: council_event_missing'])
    end

    it 'prints nothing unless it is given a stream' do
      stub_fixture
      script_runtime { |_conversation| nil }

      expect { run_benchmark }.not_to output.to_stdout
    end
  end

  describe 'the release gate' do
    it 'comes first in the report, and a run that tests nothing with a booking or a person does not pass it, however clean' do
      stub_fixture
      script_runtime { |_conversation| nil }

      report = run_benchmark(judge: true)

      expect(report.keys.first(2)).to eq(%i[gate triage])
      expect(report[:gate]).to include(verdict: 'FAIL', blockers: ['item a not covered: no appointment operation is expected anywhere in this run',
                                                                   'item f not covered: no turn asks for a person'])
      expect(report[:gate][:overall]).to include(passed: 3, total: 3, pct: 100.0)
      expect(report[:triage]).to eq([])
    end

    it 'does not pass a run that played without the judge: nothing evaluated the text of the replies (INCOMPLETE_EVALUATION)' do
      stub_fixture
      script_runtime { |_conversation| nil }

      report = run_benchmark

      expect(report).to include(judge: false)
      expect(report[:gate]).to include(judge: false)
      expect(report[:gate][:blockers]).to include('the rubric judge was off: the text of the replies was not evaluated')
      expect(run_benchmark(judge: true)[:gate][:blockers]).not_to include('the rubric judge was off: the text of the replies was not evaluated')
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

        report = run_benchmark(judge: true)

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
          report = run_benchmark(triage: file.path, judge: true)

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
    def hand_over_on_the_first_turn(**options)
      calls = 0
      script_runtime(**options) do |conversation|
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

    # A turn played on a conversation that staff owns, with nobody giving it back, cannot happen live: the case is marked, the dialogue
    # summary shows it as blocked when it fails, and the gate reports the score without it next to the score of all the turns.
    it 'marks the turn played on a conversation that staff owns and nobody gave back as blocked, and shows the gate both scores' do
      stub_fixture
      hand_over_on_the_first_turn(text: 'Пожалуйста, обращайтесь.')

      report = run_benchmark

      expect(report[:cases].pluck(:blocked)).to eq([nil, true, nil])
      expect(report[:gate][:overall]).to include(passed: 3, total: 3, blocked_turns: 1)
      expect(report[:gate][:overall_unblocked]).to include(passed: 2, total: 2, pct: 100.0)
      expect(report[:aggregates]).to include(dialogues: include(blocked_turns: 0))
    end

    it 'counts a failed blocked turn as blocked in the dialogue summary and keeps it a failed turn for the verdict' do
      fixture_data[:dialogues].first[:turns][1][:expect][:council] = true
      stub_fixture
      hand_over_on_the_first_turn(text: 'Пожалуйста, обращайтесь.')

      report = run_benchmark

      expect(report[:dialogue_summaries].sole).to include(statuses: %w[pass blocked pass])
      expect(report[:gate][:overall]).to include(passed: 2, total: 3, blocked_turns: 1)
      expect(report[:gate][:overall_unblocked]).to include(passed: 2, total: 2)
      expect(report[:gate][:blockers]).to include('overall 66.67% is below 95.0% (100.0% without the 1 blocked turn(s))')
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

    it 'tells the judge whether the conversation was handed to staff in the turn and how often in the turns before' do
      fixture_data[:dialogues].first[:turns] << { customer: 'Спасибо', staff: { status: 'pending' }, rubric: 'Благодарит.',
                                                  expect: { agent: 'Регистратор', council: false } }
      stub_fixture
      stub_judge(verdict)

      run_benchmark(judge: true)

      expect(prompts.size).to eq(2)
      expect(prompts.first).to include('Handed to staff in this turn: no. Handed to staff in earlier turns of this dialogue: 0 time(s).')
      expect(prompts.last).to include('Handed to staff in this turn: no. Handed to staff in earlier turns of this dialogue: 1 time(s).')
      expect(prompts.first).to include('A promise that staff will call or answer stands after a handoff in this turn or in an earlier one')
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

    # The judge is not a check of the agent: an answer that is no verdict, or a call that cannot be made, says nothing about the reply. It does
    # not pass the turn either (decision 3A): the turn is not evaluated, and the gate says INCOMPLETE_EVALUATION.
    it 'neither fails nor passes the turn for an answer it cannot read: not evaluated, a warning of the turn, counted apart' do
      stub_fixture
      stub_judge('не знаю')

      report = run_benchmark(judge: true)
      item = report[:cases].first

      expect(item).to include(status: 'not_evaluated', reasons: [], failures: [], not_evaluated: ['judge'], warnings: ['judge_invalid_json'])
      expect(item[:judge]).to include(unusable: 'judge_invalid_json')
      expect(report[:aggregates]).to include(passed: 1, not_evaluated: 1, judge_unusable: { turns: 1, by_check: { 'judge_invalid_json' => 1 } })
      expect(report[:warnings]).to include('judge_invalid_json: 1 turn(s)')
      expect(report[:triage]).to be_empty
      expect(report[:gate][:overall]).to include(passed: 1, total: 1, not_evaluated: 1)
      expect(report[:gate][:blockers]).to include('1 turn(s) not evaluated: a required check has no verdict (the rubric judge gave none)')
      expect(report[:gate][:not_evaluated]).to eq(turns: 1, by_check: { 'judge' => 1 })
    end

    it 'neither fails nor passes the turn for a call that cannot be made either, and names the class and the message of the error' do
      stub_fixture
      allow(Llm::Runtime).to receive(:build_chat).and_raise(TypeError, 'no implicit conversion of nil into Hash')

      item = run_benchmark(judge: true)[:cases].first

      expect(item).to include(status: 'not_evaluated', failures: [], not_evaluated: ['judge'], warnings: ['judge_unavailable'],
                              judge: { unusable: 'judge_unavailable', detail: 'TypeError: no implicit conversion of nil into Hash' })
    end

    it 'keeps the failure of a fact check on a turn the judge gave no verdict for: it is failed, not left unevaluated' do
      fixture_data[:dialogues].first[:turns].first[:expect][:agent] = 'Другой агент'
      fixture_data[:workspace][:agents] << { name: 'Другой агент', routing_description: 'Другое', instructions: 'Отвечай.', tool_ids: %w[faq_lookup] }
      stub_fixture
      stub_judge('не знаю')

      item = run_benchmark(judge: true)[:cases].first

      expect(item).to include(status: 'fail', reasons: ['wrong_agent'], not_evaluated: ['judge'])
    end

    it 'puts the hits of the text detectors into the evidence of the judge, with the language the turn expects' do
      first_turn = fixture_data[:dialogues].first[:turns].first
      first_turn[:customer] = 'запишите меня к врачу'
      first_turn[:expect][:reply_language] = 'ru'
      stub_fixture
      stub_judge(verdict)

      item = run_benchmark(judge: true)[:cases].first

      expect(item[:hints].pluck(:id)).to eq(['greeting_only_reply'])
      expect(item).to include(status: 'pass', reasons: [])
      expect(prompts.first).to include('Hints of the code heuristics for this reply: greeting_only_reply: Здравствуйте!',
                                       'is not in Russian (ru), the language of the patient')
    end

    it 'says that there is no hint when no detector found anything' do
      stub_fixture
      stub_judge(verdict)

      run_benchmark(judge: true)

      expect(prompts.first).to include('Hints of the code heuristics for this reply: none', 'is not in the language the criterion asks for')
    end

    context 'when the provider fails the call' do
      let(:flex_error) { RubyLLM::Error.new(nil, 'Flex processing is temporarily unavailable. Please try again later or use standard processing.') }

      # The judge answers `answers` in turn; an Exception in the list is raised.
      def stub_judge_answers(answers)
        allow(Llm::Runtime).to receive(:build_chat).and_return(Object.new)
        queue = answers.dup
        allow(Llm::Runtime).to receive(:ask) do |_chat, prompt, **|
          prompts << prompt
          answer = queue.size > 1 ? queue.shift : queue.first
          raise answer if answer.is_a?(Exception)

          Struct.new(:content).new(answer)
        end
      end

      it 'asks again, with a longer pause each time, and takes the verdict of the call that went through' do
        stub_fixture
        stub_judge_answers([flex_error, flex_error, verdict])
        pauses = []

        item = run_benchmark(judge: true) { |runner| allow(runner).to receive(:judge_pause) { |seconds| pauses << seconds } }[:cases].first

        expect(item).to include(status: 'pass', judge: { pass: true, reason: 'ок', attempts: 3 })
        expect(item[:warnings]).to be_blank
        expect(prompts.size).to eq(3)
        expect(pauses).to eq([2, 4])
      end

      it 'asks again for an answer that is no verdict too' do
        stub_fixture
        stub_judge_answers(['не знаю', verdict])

        item = run_benchmark(judge: true)[:cases].first

        expect(item[:judge]).to eq(pass: true, reason: 'ок', attempts: 2)
        expect(prompts.size).to eq(2)
      end

      it 'gives up after two more attempts and reports the message of the last error as the detail' do
        stub_fixture
        stub_judge_answers([flex_error])

        item = run_benchmark(judge: true)[:cases].first

        expect(prompts.size).to eq(3)
        expect(item).to include(status: 'not_evaluated', failures: [], warnings: ['judge_unavailable'])
        expect(item[:judge]).to eq(unusable: 'judge_unavailable',
                                   detail: 'RubyLLM::Error: Flex processing is temporarily unavailable. Please try again later or use standard processing.')
      end

      it 'keeps a key out of the detail and the detail short' do
        stub_fixture
        stub_judge_answers([RuntimeError.new("401 for key sk-or-v1-0123456789abcdef and Bearer abc.def #{'x' * 400}")])

        detail = run_benchmark(judge: true)[:cases].first.dig(:judge, :detail)

        expect(detail).to start_with('RuntimeError: 401 for key [key] and Bearer [key]')
        expect(detail).not_to include('0123456789abcdef', 'abc.def')
        expect(detail.length).to be <= 190
      end
    end

    # The examples above replace Llm::Runtime itself, so they could not see a judge call that the runtime cannot even build: it raised
    # TypeError (nil into Hash#merge!) before any request left, and every judged turn of a real run became judge_unavailable. Here only
    # the provider is stubbed.
    context 'when the call goes through the real runtime' do
      let(:requests) { [] }

      before do
        allow(Llm::Config).to receive(:installation_api_key).and_return('synthetic-key')
        # The installed catalog of the provider says what a request may carry: the model thinks, so it takes a reasoning effort and no
        # temperature, and an output limit.
        catalog = Llm::Models.method(:model_config)
        allow(Llm::Models).to receive(:model_config) do |name, **options|
          config = catalog.call(name, **options).to_h
          next config unless name == described_class::MODEL

          config.merge('supported_parameters' => (Array(config['supported_parameters']) | %w[reasoning max_tokens]),
                       'capabilities' => (Array(config['capabilities']) | ['reasoning']),
                       'reasoning' => { 'supported_efforts' => %w[none low medium high], 'mandatory' => false })
        end
        stub_request(:post, %r{/chat/completions}).to_return do |request|
          requests << JSON.parse(request.body)
          { status: 200, headers: { 'Content-Type' => 'application/json' },
            body: { id: 'gen-judge', object: 'chat.completion', model: described_class::MODEL,
                    choices: [{ index: 0, finish_reason: 'stop', message: { role: 'assistant', content: verdict } }],
                    usage: { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 } }.to_json }
        end
        stub_fixture
      end

      it 'asks the benchmark model first, on standard processing with reasoning, with the criterion of the turn, and reads its verdict' do
        item = run_benchmark(judge: true)[:cases].first

        # finish_reason is the one the provider answered with: it is recorded, so a limit that cut the answer off shows in the report.
        expect(item).to include(status: 'pass', judge: { pass: true, reason: 'ок', finish_reason: 'stop' })
        expect(item[:failures]).to be_empty
        expect(requests.size).to eq(1)
        # A model that answers in its place stops the run (unexpected_chat_model), as for the agents.
        expect(requests.first).to include('model' => described_class::MODEL)
        expect(requests.first['models'].first).to eq(described_class::MODEL)
        expect(requests.first).not_to include('service_tier')
        expect(requests.first.dig('provider', 'ignore')).to include('openai/flex')
        expect(requests.first.dig('reasoning', 'effort')).to eq('low')
        expect(requests.first['max_tokens']).to eq(described_class::JUDGE_MAX_TOKENS)
        expect(requests.first['messages'].pluck('content').join).to include('Criterion of this turn: Здоровается и спрашивает, чем помочь.')
      end

      context 'when the judge rejects the reply' do
        let(:verdict) { '{"pass":false,"reason":"слишком сухо"}' }

        it 'fails the turn with the reason of the judge, not with judge_unavailable' do
          item = run_benchmark(judge: true)[:cases].first

          expect(item[:reasons]).to eq(['judge_failed'])
          expect(item[:judge]).to eq(pass: false, reason: 'слишком сухо', finish_reason: 'stop')
        end
      end

      context 'when the answer is cut off by the output limit' do
        let(:requests) { [] }

        before do
          stub_request(:post, %r{/chat/completions}).to_return do |request|
            requests << JSON.parse(request.body)
            { status: 200, headers: { 'Content-Type' => 'application/json' },
              body: { id: 'gen-judge', object: 'chat.completion', model: described_class::MODEL,
                      choices: [{ index: 0, finish_reason: 'length', message: { role: 'assistant', content: '' } }],
                      usage: { prompt_tokens: 10, completion_tokens: 4000, total_tokens: 4010 } }.to_json }
          end
        end

        it 'records the finish_reason with the cause, asks again twice, and leaves the turn not evaluated' do
          item = run_benchmark(judge: true)[:cases].first

          expect(requests.size).to eq(3)
          expect(item).to include(status: 'not_evaluated', not_evaluated: ['judge'])
          expect(item[:judge]).to include(unusable: 'judge_invalid_json', finish_reason: 'length')
          expect(item[:judge][:detail]).to start_with('finish_reason length')
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
