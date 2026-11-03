require 'rails_helper'

RSpec.describe Captain::Runtime::Council::PartRun do
  let(:booking) { double('create_appointment', name: 'create_appointment', metadata: { risk_level: 'high', idempotent: false }) }
  let(:note) { double('add_private_note', name: 'add_private_note', metadata: { risk_level: 'high', idempotent: false }) }
  let(:lookup) { double('faq_lookup', name: 'faq_lookup', metadata: { read_only: true, risk_level: 'low' }) }
  let(:agent) do
    Captain::Runtime::Agent.new(name: 'assistant_2', instructions: 'Owner', tools: [booking, note, lookup],
                                response_schema: Captain::Runtime::PartSchema)
  end
  let(:snapshot) { { part_run: true, state: { assistant_id: 2 } } }
  let(:runner) { instance_double(Captain::Runtime::Runner) }
  let(:run_callbacks) { [] }
  let(:answer) do
    { 'patient_language' => 'Russian', 'customer_text' => 'Вы записаны на 14 октября в 10:00.', 'status' => 'answered', 'questions' => [],
      'sources' => ['create_appointment'], 'reasoning' => 'ok' }
  end
  let(:created) { Captain::ToolResult.success(data: { appointment_id: 7, local_date: '14.10.2026', local_time: '10:00' }) }

  def part_run(callbacks: {}, mutation_guard: nil)
    described_class.new(agent: agent, snapshot: snapshot, account: nil, llm_context: nil, callbacks: callbacks, max_turns: 14,
                        mutation_guard: mutation_guard)
  end

  # What the runner does with the callbacks of a run: it reports each tool result and each model call to them.
  def stub_run(output: answer, error: nil, context: {}, tools: [], calls: 1)
    allow(Captain::Runtime::Runner).to receive(:new).and_return(runner)
    allow(runner).to receive(:run) do |_agent, _input, **options|
      run_callbacks << options
      calls.times { options[:callbacks][:llm_call_complete].each { |callback| callback.call('assistant_2', 'model', nil, nil) } }
      tools.each { |name, result| options[:callbacks][:tool_complete].each { |callback| callback.call(name, result, nil) } }
      Captain::Runtime::Result.new(output: output, error: error, context: context)
    end
  end

  it 'runs the owner agent on the fragment with its own snapshot and turn limit, and returns the parsed structured answer' do
    stub_run(tools: [['create_appointment', created]])

    result = part_run.call('Запишите меня на 14 октября')

    expect(runner).to have_received(:run).with(agent, 'Запишите меня на 14 октября', hash_including(context: snapshot, max_turns: 14))
    expect(result[:output]).to include('status' => 'answered', 'patient_language' => 'Russian',
                                       'customer_text' => 'Вы записаны на 14 октября в 10:00.', 'sources' => ['create_appointment'])
    expect(result).to include(acted: true, pending: false, technical: nil, mutations_succeeded: 1, mutations_failed: 0,
                              mutations_unknown: 0, tools_called: 1, turns: 1)
  end

  it 'computes that an action was performed from the tool results, never from the answer' do
    stub_run(output: answer, tools: [['faq_lookup', Captain::ToolResult.success(message: 'ok')]])

    result = part_run.call('Запишите меня')

    expect(result[:output]['customer_text']).to include('записаны')
    expect(result).to include(acted: false, mutations_succeeded: 0, tools_called: 1)
  end

  it 'does not count an annotation as an action' do
    stub_run(tools: [['add_private_note', Captain::ToolResult.success(message: 'noted')]])

    expect(part_run.call('x')).to include(acted: false, mutations_succeeded: 0)
  end

  it 'counts a rejected write as failed and a write with an unknown outcome as unknown' do
    rejected = JSON.generate(success: false, reason: 'time_taken')
    unknown = Captain::ToolResult.failure(error: 'Provider did not answer', retryable: false)
    stub_run(tools: [['create_appointment', rejected], ['create_appointment', unknown]])

    expect(part_run.call('x')).to include(acted: false, mutations_succeeded: 0, mutations_failed: 1, mutations_unknown: 1, tools_called: 2)
  end

  it 'reports a write that waits for the provider as done and pending' do
    pending = JSON.generate(success: false, reason: 'pending_provider_confirmation', appointment_id: 7, provider_confirmed: false,
                            provider_confirmation_operation: 'create_reception', provider_confirmation_scope: 'medelement')
    stub_run(tools: [['create_appointment', pending]])

    expect(part_run.call('x')).to include(acted: true, pending: true)
  end

  it 'passes the technical failure of the run on and gives no answer' do
    failure = { 'tool' => 'create_appointment', 'kind' => 'technical', 'reason' => 'provider_unavailable' }
    stub_run(output: nil, error: Captain::Runtime::Runner::TechnicalFailure.new('x'), context: { technical_failure: failure })

    result = part_run.call('x')

    expect(result).to include(technical: failure, output: nil)
  end

  it 'treats an error of the run without a tool failure as a technical failure too' do
    stub_run(output: nil, error: RuntimeError.new('boom'))

    expect(part_run.call('x')[:technical]).to eq('kind' => 'technical', 'reason' => 'run_error', 'error_class' => 'RuntimeError')
  end

  it 'names a part of a suggestion that reached the deadline of the parts' do
    stub_run(output: nil, error: Captain::ReplySuggestion::RunControl::PartTimeUp.new(:turn))

    expect(part_run.call('x')[:technical]).to include('reason' => 'time_up')
  end

  describe 'a part that used up its turns or was stopped by the loop guard while it was still working' do
    let(:history) { [{ role: 'user', content: 'Сколько стоит МРТ поясницы?' }, { role: 'assistant', content: 'search_scheduling_services' }] }
    let(:stopped_context) { snapshot.merge(conversation_history: history) }

    # The runs in order: the run of the part, then the call without tools when there is one.
    def stub_runs(*results)
      allow(Captain::Runtime::Runner).to receive(:new).and_return(runner)
      allow(runner).to receive(:run) do |_agent, _input, **options|
        run_callbacks << options
        results.shift || raise('no more runs')
      end
    end

    def stopped(error_class)
      Captain::Runtime::Result.new(output: nil, error: error_class.new('stopped'), context: stopped_context)
    end

    context 'when the part runs in a reply suggestion' do
      let(:snapshot) { { part_run: true, state: { assistant_id: 2, source: 'reply_suggestion' } } }

      it 'writes its result from what its tools returned in one more call without tools, and the council gets that answer' do
        [Captain::Runtime::Runner::MaxTurnsExceeded, Captain::Runtime::Runner::ToolLoopStopped].each do |error_class|
          run_callbacks.clear
          stub_runs(stopped(error_class), Captain::Runtime::Result.new(output: answer, context: stopped_context))

          result = part_run.call('Сколько стоит МРТ поясницы?')

          expect(run_callbacks.size).to eq(2)
          expect(run_callbacks.last).to include(context: stopped_context, max_turns: 1, finalization_only: true, continue_from_history: true)
          expect(result).to include(technical: nil, output: include('status' => 'answered', 'customer_text' => answer['customer_text']))
        end
      end

      it 'stays a technical failure that names the turn limit when that call fails too' do
        stub_runs(stopped(Captain::Runtime::Runner::MaxTurnsExceeded),
                  Captain::Runtime::Result.new(output: nil, error: Captain::ReplySuggestion::RunControl::PartTimeUp.new(:turn), context: {}))

        result = part_run.call('x')

        expect(result).to include(output: nil, technical: include('kind' => 'technical', 'reason' => 'max_turns'))
      end
    end

    it 'is a technical failure at once outside a suggestion' do
      stub_runs(stopped(Captain::Runtime::Runner::MaxTurnsExceeded))

      result = part_run.call('x')

      expect(run_callbacks.size).to eq(1)
      expect(result[:technical]).to include('reason' => 'max_turns')
    end
  end

  it 'has no answer for an output that is not a structured result' do
    ['not json', { 'status' => 'done' }, nil, { 'customer_text' => 'x' }].each do |output|
      stub_run(output: output)

      expect(part_run.call('x')[:output]).to be_nil
    end
  end

  it 'treats an output that is not a structured result as a technical failure when the part did nothing, as a single agent does' do
    ['not json', { 'status' => 'done' }, nil, { 'customer_text' => 'x' }, ''].each do |output|
      stub_run(output: output)

      expect(part_run.call('x')).to include(output: nil, acted: false, technical: { 'kind' => 'technical', 'reason' => 'invalid_output' })
    end
  end

  it 'still reports an action as done when the output is not a structured result' do
    stub_run(output: 'not json', tools: [['create_appointment', created]])

    expect(part_run.call('x')).to include(output: nil, acted: true, technical: nil)
  end

  it 'reads the answer from a JSON string and drops anything but strings from the lists' do
    stub_run(output: JSON.generate(status: 'needs_information', patient_language: ' Kazakh ', customer_text: ' На какое время? ',
                                   questions: ['На какое время?', 5, nil], sources: 'x'))

    expect(part_run.call('x')[:output]).to eq('status' => 'needs_information', 'patient_language' => 'Kazakh',
                                              'customer_text' => 'На какое время?', 'questions' => ['На какое время?'], 'sources' => [],
                                              'reasoning' => '')
  end

  it 'keeps an answer that names no language, with a blank one' do
    stub_run(output: answer.except('patient_language'))

    expect(part_run.call('x')[:output]).to include('customer_text' => 'Вы записаны на 14 октября в 10:00.', 'patient_language' => '')
  end

  it 'keeps external callback lists and binds the shared guard before external run-start callbacks' do
    seen = []
    guard = Monitor.new
    callbacks = { tool_complete: [->(name, *) { seen << name }],
                  run_start: [->(_name, _input, wrapper) { seen << wrapper.council_mutation_guard }] }
    original_callbacks = callbacks.transform_values(&:dup)
    stub_run(tools: [['faq_lookup', Captain::ToolResult.success(message: 'ok')]])

    part_run(callbacks: callbacks, mutation_guard: guard).call('x')
    wrapper = Captain::Runtime::RunContext.new({})
    run_callbacks.sole[:callbacks][:run_start].each { |callback| callback.call('assistant_2', 'x', wrapper) }

    expect(seen).to eq(['faq_lookup', guard])
    expect(callbacks).to eq(original_callbacks)
    expect(wrapper.context).to eq({})
  end

  it 'returns the tool tracking without the appointment evidence, and nothing but plain data' do
    context = { captain_v2_completed_tool_names: ['create_appointment'], captain_v2_artifact_ids: ['doc-1'],
                captain_v2_completed_actions: ['create_appointment'],
                captain_v2_completed_tool_results: [{ tool_name: 'create_appointment', success: true, appointment_evidence: { action: 'update_appointment' } }] }
    stub_run(context: context)

    tracking = part_run.call('x')[:tracking]

    expect(tracking).to eq(completed_tool_names: ['create_appointment'], completed_actions: ['create_appointment'],
                           completed_tool_results: [{ tool_name: 'create_appointment', success: true }], artifact_ids: ['doc-1'],
                           outcome_facts: {}, pending_actions: [])
  end

  it 'keeps what the tools did when the run turns stale' do
    allow(Captain::Runtime::Runner).to receive(:new).and_return(runner)
    allow(runner).to receive(:run) do |_agent, _input, **options|
      options[:callbacks][:tool_complete].each { |callback| callback.call('create_appointment', created, nil) }
      raise Captain::Conversation::ControlGenerationStaleError, 'newer message'
    end
    run = part_run

    expect { run.call('x') }.to raise_error(Captain::Conversation::ControlGenerationStaleError)
    expect(run.tracker).to be_acted
    expect(run.tracker.summary).to include('create_appointment')
  end
end
