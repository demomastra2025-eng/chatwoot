# frozen_string_literal: true

require 'rails_helper'

# A council in a reply suggestion writes nothing (an action tool only prepares an approval card), so its parts run side by side
# with a turn cap that fits the budget of the suggestion. The runs of the parts are stubbed with fake timings. The owners are plain
# doubles, as in council_spec.rb: the agent runtime they hand out is a real Captain::Runtime::Agent.
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
  let(:council) { described_class.new(context: context, graph: graph, account: nil, llm_context: :llm_context) }

  # Every owner has an action tool: in a live run each would be a writer of the one writer lane.
  def actor(id)
    tool = double("write tool #{id}", name: 'create_appointment', metadata: { risk_level: 'high', idempotent: false })
    runtime = Captain::Runtime::Agent.new(name: "assistant_#{id}", instructions: 'Owner', tools: [tool])
    double("actor #{id}", id: id, name: "Агент #{id}", agent_name: "assistant_#{id}", config: {}, prompt_context_state: {}, agent: runtime,
                          avatar_url: nil, handoff_enabled?: true, selected_agent_tool_ids: %w[handoff], resolved_agent_model: 'openai/gpt-6-luna')
  end

  def parts
    items = [1, 2, 3].map do |owner|
      { 'id' => "part-#{owner}", 'version' => 1, 'executor_agent_id' => owner, 'fragment' => "Запрос #{owner}", 'patient' => 'Анна',
        'relation' => 'independent', 'state' => 'open', 'delivered' => [] }
    end
    context[:parts] = items.deep_dup
    items
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
          sleep part_seconds
          answered("Ответ на #{fragment}")
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

  it 'gives the parts on their threads the control of the suggestion run (its cancel, its deadline, its cards)' do
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 60
    control = nil

    Captain::ReplySuggestion::RunControl.with(request_id: SecureRandom.uuid, deadline: deadline) do |run_control|
      control = run_control
      council.run(parts)
    end

    expect(built.pluck(:control_seen)).to all(be(control))
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

  describe 'the budget of a routed suggestion (fake timings)' do
    # The slowest step of each stage: the router (its chain and its escalation), the split, the slowest part (every turn a model
    # call of about 8 s), the editor.
    def worst_case_seconds(part_turns, turn_seconds: 8)
      settings = Captain::Runtime::DecisionRouter::Settings
      routing = settings.chain_budget_seconds + settings.escalation_timeout_seconds
      split = Llm::FeatureProfile.for(Captain::Runtime::CouncilSplitter::FEATURE).timeout_seconds
      routing + split + (part_turns * turn_seconds) + Captain::Runtime::CouncilEditor::TIMEOUT_SECONDS
    end

    it 'fits a council within the router budget of a suggestion' do
      expect(worst_case_seconds(described_class::SUGGESTION_PART_MAX_TURNS))
        .to be <= Captain::ReplySuggestion.budget_seconds(router: true)
    end

    it 'would not fit with the live turn cap or within the budget of a single agent' do
      expect(worst_case_seconds(described_class::PART_MAX_TURNS)).to be > Captain::ReplySuggestion.budget_seconds(router: true)
      expect(worst_case_seconds(described_class::SUGGESTION_PART_MAX_TURNS)).to be > Captain::ReplySuggestion.budget_seconds
    end
  end
end
# rubocop:enable RSpec/VerifiedDoubles
