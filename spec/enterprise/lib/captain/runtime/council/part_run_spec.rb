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
      'sources' => ['create_appointment'], 'suggested_agent' => '', 'reasoning' => 'ok' }
  end
  let(:created) { Captain::ToolResult.success(data: { appointment_id: 7, local_date: '14.10.2026', local_time: '10:00' }) }

  def part_run(callbacks: {})
    described_class.new(agent: agent, snapshot: snapshot, account: nil, llm_context: nil, callbacks: callbacks, max_turns: 14)
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
                                   questions: ['На какое время?', 5, nil], sources: 'x', suggested_agent: 3))

    expect(part_run.call('x')[:output]).to eq('status' => 'needs_information', 'patient_language' => 'Kazakh',
                                              'customer_text' => 'На какое время?', 'questions' => ['На какое время?'], 'sources' => [],
                                              'suggested_agent' => '', 'reasoning' => '')
  end

  it 'keeps an answer that names no language, with a blank one' do
    stub_run(output: answer.except('patient_language'))

    expect(part_run.call('x')[:output]).to include('customer_text' => 'Вы записаны на 14 октября в 10:00.', 'patient_language' => '')
  end

  it 'keeps the callbacks of the run and adds its own, without changing the lists it was given' do
    seen = []
    callbacks = { tool_complete: [->(name, *) { seen << name }], run_start: [-> {}] }
    stub_run(tools: [['faq_lookup', Captain::ToolResult.success(message: 'ok')]])

    part_run(callbacks: callbacks).call('x')

    expect(seen).to eq(['faq_lookup'])
    expect(callbacks[:tool_complete].size).to eq(1)
    expect(run_callbacks.sole[:callbacks][:run_start].size).to eq(1)
  end

  it 'returns the tool tracking without the appointment evidence, and nothing but plain data' do
    context = { captain_v2_completed_tool_names: ['create_appointment'], captain_v2_artifact_ids: ['doc-1'],
                captain_v2_completed_actions: ['create_appointment'],
                captain_v2_completed_tool_results: [{ tool_name: 'create_appointment', success: true, appointment_evidence: { action: 'update_appointment' } }] }
    stub_run(context: context)

    tracking = part_run.call('x')[:tracking]

    expect(tracking).to eq(completed_tool_names: ['create_appointment'], completed_actions: ['create_appointment'],
                           completed_tool_results: [{ tool_name: 'create_appointment', success: true }], artifact_ids: ['doc-1'],
                           outcome_facts: {})
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
