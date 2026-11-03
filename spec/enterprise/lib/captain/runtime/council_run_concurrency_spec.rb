# frozen_string_literal: true

require 'rails_helper'
require 'timeout'

# Real council, part runner, tool wrappers and DB-backed session. Only the model
# transport and the tools' business effects are scripted. No fixture transaction
# is shared with the workers; receipts are committed and read back from the DB.
RSpec.describe Captain::Runtime::Council, '#run' do
  self.use_transactional_tests = false

  let(:account) { create(:account) }
  let(:conversation) do
    create(:conversation, account: account, status: :pending).tap do |item|
      create(:captain_inbox, inbox: item.inbox, reply_to_open_conversations: false)
    end
  end
  let(:actors) { Array.new(8) { create(:captain_assistant, account: account) } }
  let(:session) do
    Captain::Conversation::AgentSession.new(
      conversation: conversation, fence: { control_generation: conversation.captain_control_generation }
    )
  end
  let(:graph) do
    instance_double(Captain::AgentGraph, inbox: nil, agents: actors).tap do |item|
      allow(item).to receive(:find) { |id| actors.find { |actor| actor.id == id } }
    end
  end
  let(:context) do
    { state: { account_id: account.id, assistant_id: actors.first.id, source: 'incoming_message',
               conversation: { id: conversation.id }, runtime_clock: { now_utc: '2026-11-03T00:00:00Z', timezone: 'Asia/Almaty' } },
      agent_session: session, agent_graph: actors.map { |actor| { id: actor.id } }, parts: [],
      agent_request_id: 'synthetic-concurrent-request', captain_v2_current_input: 'Independent requests', conversation_history: [] }
  end
  let(:council) { described_class.new(context: context, graph: graph, account: account) }
  let(:scripts) { {} }
  let(:wrappers) { [] }
  let(:fixture_lock) { Mutex.new }
  let(:chat_class) do
    Class.new do
      attr_reader :messages

      def initialize(wrapper, script)
        @wrapper = wrapper
        @script = script
        @messages = []
      end

      def ask(input)
        @messages << RubyLLM::Message.new(role: :user, content: input)
        @script.call(@wrapper).tap { |message| @messages << message }
      end
    end
  end

  def tool(name, metadata, &)
    Class.new(Captain::Runtime::Tool) do
      param :title, type: :string, required: false
      define_method(:name) { name }
      define_method(:description) { name }
      define_method(:metadata) { metadata }
      define_method(:perform, &)
    end.new
  end

  def owner_tools(actor, tools)
    runtime = Captain::Runtime::Agent.new(name: "assistant_#{actor.id}", instructions: 'Owner instructions', tools: tools)
    allow(actor).to receive(:agent).and_return(runtime)
  end

  def answer(id, sources: ['lookup_contact'])
    RubyLLM::Message.new(role: :assistant, content: JSON.generate(
      status: 'answered', customer_text: "Answer #{id}", patient_language: 'English', questions: [], sources: sources, reasoning: ''
    ))
  end

  def plan(count, chained: false)
    session.update_routing(actor_id: actors.first.id)
    raw = actors.first(count).map { |actor| { executor_agent_id: actor.id, fragment: "Request #{actor.id}", relation: 'independent' } }
    parts = Captain::Runtime::PartRegistry.new(context).accept!(mode: 'council', parts: raw)[:parts]
    if chained
      parts.drop(1).each_with_index do |part, index|
        part.merge!('relation' => 'depends_on', 'depends_on_part_id' => parts[index]['id'])
      end
    end
    parts
  end

  def pop(queue)
    Timeout.timeout(10) { queue.pop }
  end

  def on_caller_thread(parts)
    scope = Captain::Runtime::Council::ThreadScope.capture
    Thread.new do
      Thread.current.report_on_exception = false
      scope.run { council.run(parts) }
    end
  end

  def blocked_read(queues)
    tool('lookup_contact', read_only: true) do |tool_context, **|
      queues[:read_started] << [tool_context.state[:assistant_id], Current.executed_by.id, Current.account.id]
      queues[:read_release].pop
      Captain::ToolResult.success(message: 'Read complete')
    end
  end

  def blocked_write(queues, counter, lock)
    tool('create_appointment', risk_level: 'high', idempotent: false) do |tool_context, **|
      lock.synchronize do
        counter[:active] += 1
        counter[:maximum] = [counter[:maximum], counter[:active]].max
      end
      queues[:write_started] << tool_context.state[:assistant_id]
      queues[:write_release].pop
      Captain::ToolResult.success(data: { appointment_id: tool_context.state[:assistant_id] })
    ensure
      lock.synchronize { counter[:active] -= 1 }
    end
  end

  def concurrent_owner(actor, queues, counter, lock)
    read = blocked_read(queues)
    write = blocked_write(queues, counter, lock)
    owner_tools(actor, [read, write])
    scripts[actor.id] = lambda do |wrapper|
      id = wrapper.context.dig(:state, :assistant_id)
      queues[:model_started] << [id, ActiveRecord::Base.connection_pool.active_connection?.present?]
      queues[:model_release].pop
      Captain::Runtime::ToolWrapper.new(read, wrapper).call({})
      queues[:write_attempted] << id
      Captain::Runtime::ToolWrapper.new(write, wrapper).call(title: "Request #{id}")
      answer(id, sources: %w[lookup_contact create_appointment])
    end
  end

  def expect_durable_receipts
    receipts = Captain::Conversation::AgentSession.new(conversation: conversation).read.fetch('operations').values
    expected = actors.first(2).map { |actor| include('actor_id' => actor.id, 'status' => 'finished', 'outcome' => 'success') }
    expect(receipts).to match_array(expected)
  end

  def expect_isolated_guard
    expect(wrappers.map(&:council_mutation_guard).uniq.size).to eq(1)
    expect(wrappers.flat_map { |wrapper| wrapper.context.keys.map(&:to_s) }.grep(/mutation_guard/)).to be_empty
    expect(session.read.to_json).not_to include('mutation_guard', 'Monitor')
  end

  before do
    allow(council).to receive(:fresh_actor) { |id| actors.find { |actor| actor.id == id } }
    allow(described_class).to receive(:parallel?).and_return(true)
    allow(Captain::AssistantSafetyPreferences).to receive(:for).and_return({})
    allow(Llm::EventBus).to receive(:publish)
    allow(Captain::Runtime::CouncilEditor).to receive(:new).and_return(
      instance_double(Captain::Runtime::CouncilEditor).tap do |editor|
        allow(editor).to receive(:edit) { |parts:, **| Captain::Runtime::CouncilEditor::Outcome.new(reply: parts.pluck('text').join(' ')) }
      end
    )
    allow(Captain::Runtime::ChatFactory).to receive(:build) do |agent:, context_wrapper:, **|
      fixture_lock.synchronize { wrappers << context_wrapper }
      # A legacy .connection user during chat construction must not hold the
      # lease when the following model call waits on its transport.
      ActiveRecord::Base.connection.select_value('SELECT 1')
      chat_class.new(context_wrapper, scripts.fetch(agent.assistant_id))
    end
    allow(Llm::Runtime).to receive(:ask) { |chat, input, **| chat.ask(input) }
    Current.account = account
  end

  after { Current.reset }

  it 'overlaps model/read work of two action-capable owners while serializing actual writes and recording both durable receipts' do
    queues = %i[model_started model_release read_started read_release write_attempted write_started write_release].index_with { Queue.new }
    counter = { active: 0, maximum: 0 }
    counter_lock = Mutex.new
    actors.first(2).each { |actor| concurrent_owner(actor, queues, counter, counter_lock) }
    worker = on_caller_thread(plan(2))

    expect(Array.new(2) { pop(queues[:model_started]) }.map(&:last)).to eq([false, false])
    2.times { queues[:model_release] << true }
    reads = Array.new(2) { pop(queues[:read_started]) }
    expect(reads).to match_array(actors.first(2).map { |actor| [actor.id, actor.id, account.id] })
    2.times { queues[:read_release] << true }
    expect(Array.new(2) { pop(queues[:write_attempted]) }).to match_array(actors.first(2).map(&:id))
    first = pop(queues[:write_started])
    queues[:write_release] << true
    second = pop(queues[:write_started])
    queues[:write_release] << true
    expect(Timeout.timeout(10) { worker.value }).to include("Answer #{first}", "Answer #{second}")
    expect(counter[:maximum]).to eq(1)
    expect_durable_receipts
    expect_isolated_guard
  ensure
    queues&.values_at(:model_release, :read_release, :write_release)&.each { |queue| 4.times { queue << true } }
    worker&.join(10)
  end

  [5, 8].each do |count|
    it "runs and returns every one of #{count} selected parts without borrowing a connection during model waits" do
      seen = Queue.new
      actors.each do |actor|
        owner_tools(actor, [tool('create_appointment', risk_level: 'high') { |*, **| raise 'No action requested' }])
        scripts[actor.id] = lambda do |wrapper|
          seen << [wrapper.context.dig(:state, :assistant_id), ActiveRecord::Base.connection_pool.active_connection?.present?]
          answer(actor.id)
        end
      end

      reply = council.run(plan(count))

      expect(Array.new(count) { pop(seen) }).to match_array(actors.first(count).map { |actor| [actor.id, false] })
      expect(actors.first(count).map { |actor| reply.include?("Answer #{actor.id}") }).to all(be(true))
      expect(session.read.fetch('parts').size).to eq(count)
      expect(wrappers.map { |wrapper| wrapper.context.dig(:state, :runtime_clock) }.uniq).to eq([context.dig(:state, :runtime_clock)])
      expect(wrappers.map { |wrapper| wrapper.context.dig(:state, :runtime_clock).object_id }.uniq.size).to eq(count)
    end
  end

  it 'keeps a dependent chain on one lane in prerequisite order' do
    seen = Queue.new
    actors.each do |actor|
      owner_tools(actor, [])
      scripts[actor.id] = lambda do |_wrapper|
        seen << [actor.id, Thread.current.object_id]
        answer(actor.id)
      end
    end

    council.run(plan(5, chained: true))

    results = Array.new(5) { pop(seen) }
    expect(results.map(&:first)).to eq(actors.first(5).map(&:id))
    expect(results.map(&:last).uniq.size).to eq(1)
  end

  it 'protects eight durable writes and inline registry bookkeeping with the same guard under the five-connection pool' do
    guards_at_session_change = Queue.new
    actors.each do |actor|
      write = tool('create_appointment', risk_level: 'high', idempotent: false) do |tool_context, **|
        Captain::ToolResult.success(data: { appointment_id: tool_context.state[:assistant_id] })
      end
      owner_tools(actor, [write])
      scripts[actor.id] = lambda do |wrapper|
        Captain::Runtime::ToolWrapper.new(write, wrapper).call(title: "Request #{actor.id}")
        answer(actor.id, sources: ['create_appointment'])
      end
    end
    parts = plan(8)
    allow(session).to receive(:change).and_wrap_original do |original, &block|
      guards_at_session_change << council.instance_variable_get(:@mutation_guard).mon_owned?
      original.call(&block)
    end

    reply = council.run(parts)

    expect(actors.map { |actor| reply.include?("Answer #{actor.id}") }).to all(be(true))
    expect(session.read.fetch('operations').values).to all(include('status' => 'finished', 'outcome' => 'success'))
    expect(session.read.fetch('operations').size).to eq(8)
    expect(Array.new(guards_at_session_change.size) { pop(guards_at_session_change) }).to all(be(true))
  end

  it 'keeps execution inline when the caller holds a real transaction' do
    actors.each do |actor|
      owner_tools(actor, [])
      scripts[actor.id] = ->(_wrapper) { answer(actor.id) }
    end
    parts = plan(2)
    expect(council).not_to receive(:start_thread)

    ActiveRecord::Base.transaction { council.run(parts) }

    expect(wrappers.size).to eq(2)
  end

  it 'releases the shared action guard after an exception and retains the uncertain receipt while another part finishes' do
    first, second = actors.first(2)
    actors.each do |actor|
      write = tool('create_appointment', risk_level: 'high', idempotent: false) do |tool_context, **|
        raise 'Synthetic provider failure' if tool_context.state[:assistant_id] == first.id

        Captain::ToolResult.success(data: { appointment_id: tool_context.state[:assistant_id] })
      end
      owner_tools(actor, [write])
      scripts[actor.id] = lambda do |wrapper|
        Captain::Runtime::ToolWrapper.new(write, wrapper).call(title: "Request #{actor.id}")
        answer(actor.id, sources: ['create_appointment'])
      end
    end

    reply = Timeout.timeout(10) { council.run(plan(2)) }
    receipts = session.read.fetch('operations').values.index_by { |receipt| receipt['actor_id'] }

    expect(reply).to include("Answer #{second.id}")
    expect(receipts.fetch(first.id)).to include('status' => 'executing')
    expect(receipts.fetch(second.id)).to include('status' => 'finished', 'outcome' => 'success')
  end
end
