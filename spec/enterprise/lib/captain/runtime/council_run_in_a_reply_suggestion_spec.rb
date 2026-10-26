# frozen_string_literal: true

require 'rails_helper'

# A council in a reply suggestion writes nothing (an action tool only prepares an approval card), so its parts run side by side,
# against a deadline of their own that leaves the editor its time. The runs of the parts are stubbed with fake timings; like a real
# run they pass a checkpoint before each turn. The owners are plain doubles, as in council_spec.rb: the agent runtime they hand out
# is a real Captain::Runtime::Agent.
# rubocop:disable RSpec/VerifiedDoubles
RSpec.describe Captain::Runtime::Council, '#run in a reply suggestion' do
  let(:part_seconds) { 0.4 }
  let(:built) { [] }
  let(:actors) { { 1 => actor(1), 2 => actor(2), 3 => actor(3) } }
  let(:graph) do
    instance_double(Captain::AgentGraph, entry: actors[1], inbox: nil, agents: actors.values).tap do |item|
      allow(item).to receive(:find) { |id| actors[id] }
    end
  end
  let(:context) do
    { parts: [], state: { assistant_id: 1, source: 'reply_suggestion', conversation: { id: 7 } },
      captain_v2_current_input: 'Запишите к ЛОРу, на аудиометрию и узнайте цену септопластики',
      conversation_history: [{ role: 'user', content: 'Здравствуйте' }] }
  end
  let(:reassigner) { nil }
  let(:council) { described_class.new(context: context, graph: graph, account: nil, llm_context: :llm_context, reassigner: reassigner) }
  let(:part_outputs) { {} }

  # Every owner has an action tool: in a live run each would be a writer of the one writer lane.
  def actor(id)
    tool = double("write tool #{id}", name: 'create_appointment', metadata: { risk_level: 'high', idempotent: false })
    runtime = Captain::Runtime::Agent.new(name: "assistant_#{id}", instructions: 'Owner', tools: [tool])
    double("actor #{id}", id: id, name: "Агент #{id}", agent_name: "assistant_#{id}", config: {}, prompt_context_state: {}, agent: runtime,
                          avatar_url: nil, handoff_enabled?: true, selected_agent_tool_ids: %w[handoff], resolved_agent_model: 'openai/gpt-6-luna')
  end

  def parts(chained: false)
    items = [1, 2, 3].map do |owner|
      { 'id' => "part-#{owner}", 'version' => 1, 'executor_agent_id' => owner, 'fragment' => "Запрос #{owner}", 'patient' => 'Анна',
        'relation' => 'independent', 'state' => 'open', 'delivered' => [] }
    end
    items.drop(1).each_with_index { |item, index| item.merge!('relation' => 'depends_on', 'depends_on_part_id' => "part-#{index + 1}") } if chained
    context[:parts] = items.deep_dup
    items
  end

  def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  # A suggestion run whose parts have `seconds` before their own deadline (the run keeps the editor's reserve after it).
  def in_suggestion_run(seconds, &)
    deadline = now + described_class::SUGGESTION_AFTER_PARTS_SECONDS + seconds
    Captain::ReplySuggestion::RunControl.with(request_id: SecureRandom.uuid, deadline: deadline, &)
  end

  def answered(text)
    { output: { 'patient_language' => 'Russian', 'status' => 'answered', 'customer_text' => text, 'questions' => [],
                'sources' => ['search_available_slots'], 'reasoning' => '' },
      acted: false, pending: false, technical: nil, summary: '', duration_ms: 1, tracking: {}, mutations_succeeded: 0,
      mutations_failed: 0, mutations_unknown: 0, tools_called: 2, turns: 3 }
  end

  before do
    allow(Captain::AssistantSafetyPreferences).to receive(:for).and_return({})
    allow(Captain::Runtime::CouncilEditor).to receive(:new)
      .and_return(instance_double(Captain::Runtime::CouncilEditor, edit: Captain::Runtime::CouncilEditor::Outcome.new(reply: 'Единый ответ.')))
    allow(council).to receive(:fresh_actor) { |id| actors[id] }
    %i[council_started council_finished council_edited council_editor_fallback part_started part_finished].each do |event|
      allow(Captain::Runtime::CoordinationEvents).to receive(event)
    end
    allow(described_class).to receive(:parallel?).and_return(true)
    allow(Captain::Runtime::Council::PartRun).to receive(:new) do |snapshot:, max_turns:, **|
      built << { part: snapshot[:active_part_id], max_turns: max_turns, session: snapshot.key?(:agent_session) }
      double('part run', tracker: double('tracker', acted?: false, summary: '')).tap do |run|
        allow(run).to receive(:call) do |fragment|
          built.find { |item| item[:part] == snapshot[:active_part_id] }[:control_seen] = Captain::ReplySuggestion::RunControl.current
          Captain::ReplySuggestion::RunControl.checkpoint!(:turn)
          sleep part_seconds
          Captain::ReplySuggestion::RunControl.checkpoint!(:turn)
          part_outputs.fetch(snapshot[:active_part_id]) { answered("Ответ на #{fragment}") }
        end
      end
    end
  end

  after { Current.reset }

  it 'runs the parts side by side within the time of the slowest part, each with the suggestion turn cap' do
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    reply = council.run(parts)
    seconds = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    expect(reply).to eq('Единый ответ.')
    # One after another the three parts would take 3 x 0.4 s.
    expect(seconds).to be < part_seconds * 2
    expect(built.pluck(:max_turns)).to all(eq(described_class::SUGGESTION_PART_MAX_TURNS))
    expect(built.pluck(:session)).to all(be(false))
  end

  it 'gives the parts on their threads the control of the suggestion run (its cancel, its deadline, its cards) with their deadline' do
    control = nil

    in_suggestion_run(60) do |run_control|
      control = run_control
      council.run(parts)
    end

    expect(built.pluck(:control_seen)).to all(be_a(Captain::ReplySuggestion::RunControl::PartScope))
    expect(built.map { |item| item[:control_seen].request_id }).to all(eq(control.request_id))
  end

  it 'keeps the live turn cap and the one writer lane outside a suggestion' do
    context[:state][:source] = 'incoming_message'
    live = described_class.new(context: context, graph: graph, account: nil, llm_context: :llm_context)
    allow(live).to receive(:fresh_actor) { |id| actors[id] }
    allow(live).to receive(:staff_handoff_available?).and_return(false)

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    live.run(parts)

    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be >= part_seconds * 3
    expect(built.pluck(:max_turns)).to all(eq(described_class::PART_MAX_TURNS))
  end

  describe 'the deadline of the parts (real timings, the run keeps the time of the editor)' do
    def finished_within(seconds)
      started = now
      result = yield
      expect(now - started).to be < seconds
      result
    end

    it 'stops the slow part of a lane of dependent parts, answers with the part that finished and names the stopped ones' do
      reply = finished_within(1.4) { in_suggestion_run(0.6) { council.run(parts(chained: true)) } }

      expect(reply).to eq('Ответ на Запрос 1')
      expect(context[:council_handoff]).to include(technical: true, failed_parts: ['Запрос 2', 'Запрос 3'])
      expect(context[:technical_failure]).to be_nil
      expect(built.pluck(:part)).to eq(%w[part-1 part-2])
    end

    it 'stops the parts of a run that got no thread (one after another on the calling thread) at the same deadline' do
      allow(described_class::SLOTS).to receive(:try_acquire).and_return(false)

      reply = finished_within(1.4) { in_suggestion_run(0.6) { council.run(parts) } }

      expect(reply).to eq('Ответ на Запрос 1')
      expect(context[:council_handoff]).to include(technical: true, failed_parts: ['Запрос 2', 'Запрос 3'])
    end

    context 'with a part that answers it is not its own' do
      let(:decisions) { [] }
      let(:reassigner) do
        lambda do |**arguments|
          decisions << arguments
          nil
        end
      end

      before do
        part_outputs['part-1'] = answered('').merge(output: { 'patient_language' => 'Russian', 'status' => 'out_of_scope', 'customer_text' => '',
                                                              'questions' => [], 'sources' => [], 'reasoning' => '' })
      end

      it 'decides it again only while the router and a short run still fit' do
        in_suggestion_run(10) { council.run(parts) }
        expect(decisions).to be_empty

        second = described_class.new(context: context, graph: graph, account: nil, reassigner: reassigner)
        allow(second).to receive(:fresh_actor) { |id| actors[id] }
        in_suggestion_run(60) { second.run(parts) }
        expect(decisions.pluck(:fragment)).to eq(['Запрос 1'])
      end
    end

    it 'never fails a suggestion council without a text for a technical failure of its parts: it names them to the manager' do
      technical = answered('').merge(output: nil, technical: { 'kind' => 'technical', 'reason' => 'provider_unavailable' })
      %w[part-1 part-2 part-3].each { |id| part_outputs[id] = technical }

      reply = in_suggestion_run(30) { council.run(parts) }

      expect(reply).to eq('')
      expect(context[:technical_failure]).to be_nil
      expect(context[:council_handoff]).to include(technical: true, failed_parts: ['Запрос 1', 'Запрос 2', 'Запрос 3'])
    end
  end

  describe 'a part that needs no reply (a thanks, an ok)' do
    let(:no_reply) do
      answered('').merge(output: { 'patient_language' => 'Russian', 'status' => 'no_reply_needed', 'customer_text' => '', 'questions' => [],
                                   'sources' => [], 'reasoning' => '' })
    end

    it 'sends nothing and hands nothing to staff when no part needs a reply, and says so' do
      %w[part-1 part-2 part-3].each { |id| part_outputs[id] = no_reply }

      reply = in_suggestion_run(30) { council.run(parts) }

      expect(reply).to eq('')
      expect(context).not_to have_key(:council_handoff)
      expect(context[:council_no_reply]).to be(true)
      expect(context[:parts].pluck('state')).to all(eq('answered'))
    end

    it 'answers the other parts without the thanks and without staff' do
      part_outputs['part-2'] = no_reply

      reply = in_suggestion_run(30) { council.run(parts) }

      expect(reply).to eq('Единый ответ.')
      expect(Captain::Runtime::CouncilEditor).to have_received(:new).once
      expect(context).not_to have_key(:council_handoff)
      expect(context).not_to have_key(:council_no_reply)
    end
  end

  it 'gives every part its final status for the manager, also a part that stopped without a result of its own' do
    part_outputs['part-3'] = answered('').merge(output: nil, technical: { 'kind' => 'technical', 'reason' => 'max_turns' })

    in_suggestion_run(30) { council.run(parts) }

    expect(context[:council_part_statuses]).to eq([{ 'id' => 'part-1', 'status' => 'answered' }, { 'id' => 'part-2', 'status' => 'answered' },
                                                   { 'id' => 'part-3', 'status' => 'unavailable', 'stop_reason' => 'max_turns' }])
    expect(context[:council_part_statuses].pluck('status')).not_to include('running')
    expect(context[:council_handoff]).to include(technical: true, failed_parts: ['Запрос 3'])
  end
end
# rubocop:enable RSpec/VerifiedDoubles
