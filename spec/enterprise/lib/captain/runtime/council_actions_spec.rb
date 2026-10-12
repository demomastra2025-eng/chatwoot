require 'rails_helper'

# The whole path of a council part that acts: the plan of the registry, the council, the real run of the owner (scripted model, real
# tool wrapper), the durable session and its receipts. Only the model and the tools themselves are fakes.
# rubocop:disable Lint/ConstantDefinitionInBlock
RSpec.describe Captain::Runtime::Council, 'with parts that act' do
  class CouncilActionsSpecBookingTool < Captain::Runtime::Tool
    param :title, type: :string, required: true

    attr_reader :calls
    attr_writer :result

    def initialize
      super
      @calls = []
    end

    def name = 'create_appointment'
    def description = 'Create an appointment'
    def metadata = { risk_level: 'high', idempotent: false }

    def perform(_tool_context, title:)
      @calls << title
      @result || Captain::ToolResult.success(data: { appointment_id: @calls.size, doctor_name: 'Иванов', local_date: '14.10.2026', local_time: '10:00' })
    end
  end

  class CouncilActionsSpecPriceTool < Captain::Runtime::Tool
    param :query, type: :string, required: false

    def name = 'faq_lookup'
    def description = 'Look up the price list'
    def metadata = { read_only: true, risk_level: 'low' }

    def perform(_tool_context, **)
      'МРТ стоит 15000 тенге.'
    end
  end

  # A model that follows a script: each step gets the chat, so it can call the tools of the run like a model does.
  class CouncilActionsSpecChat
    attr_accessor :context_wrapper
    attr_reader :messages

    def initialize
      @messages = []
      @steps = []
    end

    def script(*steps)
      @steps.concat(steps)
      self
    end

    def add_message(message_or_attributes)
      message = message_or_attributes.is_a?(RubyLLM::Message) ? message_or_attributes : RubyLLM::Message.new(message_or_attributes)
      @messages << message
      message
    end

    def ask(input)
      add_message(role: :user, content: input)
      next_response
    end

    def complete
      next_response
    end

    private

    def next_response
      step = @steps.shift || raise('The model was asked again, but the script is over')
      response = step.call(self)
      add_message(response) if response.is_a?(RubyLLM::Message)
      response
    end
  end

  let(:entry) { create(:captain_assistant) }
  let(:current_id) { entry.id }
  let(:writer_id) { entry.id + 101 }
  let(:reader_id) { entry.id + 102 }
  let(:session) { Captain::Conversation::AgentSession.new(entry: entry) }
  let(:booking) { CouncilActionsSpecBookingTool.new }
  let(:price) { CouncilActionsSpecPriceTool.new }
  let(:chats) { { "assistant_#{writer_id}" => CouncilActionsSpecChat.new, "assistant_#{reader_id}" => CouncilActionsSpecChat.new } }
  let(:writer_chat) { chats.fetch("assistant_#{writer_id}") }
  let(:reader_chat) { chats.fetch("assistant_#{reader_id}") }
  let(:editor) { instance_double(Captain::Runtime::CouncilEditor) }
  let(:actors) { { writer_id => actor(writer_id, [booking]), reader_id => actor(reader_id, [price]) } }
  let(:graph) do
    instance_double(Captain::AgentGraph, entry: actors[writer_id], inbox: nil, agents: actors.values).tap do |item|
      allow(item).to receive(:find) { |id| actors[id] }
    end
  end
  let(:agent_graph) do
    [{ id: current_id, name: 'Администратор', description: 'Приём' }, { id: writer_id, name: 'Запись', description: 'Запись на приём' },
     { id: reader_id, name: 'Цены', description: 'Прайс' }]
  end
  let(:order) { [] }

  def actor(id, tools)
    runtime = Captain::Runtime::Agent.new(name: "assistant_#{id}", instructions: 'Owner', tools: tools)
    double("actor #{id}", id: id, name: "Агент #{id}", agent_name: "assistant_#{id}", config: {}, prompt_context_state: {}, agent: runtime,
                          avatar_url: nil, handoff_enabled?: true, selected_agent_tool_ids: %w[handoff], resolved_agent_model: 'openai/gpt-6-luna')
  end

  def new_context(request_id, input)
    { state: { assistant_id: current_id, entry_assistant_id: entry.id }, agent_graph: agent_graph, agent_session: session,
      agent_request_id: request_id, parts: session.read['parts'], captain_v2_current_input: input, conversation_history: [] }
  end

  def answer(text, status: 'answered', sources: ['faq_lookup'], questions: [])
    RubyLLM::Message.new(role: :assistant, content: JSON.generate(customer_text: text, status: status, questions: questions, sources: sources,
                                                                  suggested_agent: '', reasoning: ''))
  end

  def books(title, text: 'Вы записаны к терапевту Иванову на 14 октября в 10:00.')
    lambda do |chat|
      Captain::Runtime::ToolWrapper.new(booking, chat.context_wrapper).call(title: title)
      answer(text, sources: ['create_appointment'])
    end
  end

  def looks_up_the_price
    lambda do |chat|
      Captain::Runtime::ToolWrapper.new(price, chat.context_wrapper).call({})
      answer('МРТ стоит 15000 тенге.')
    end
  end

  def asks(question)
    ->(_chat) { answer(question, status: 'needs_information', questions: [question], sources: []) }
  end

  def plan_for(context, parts, mode: 'council')
    Captain::Runtime::PartRegistry.new(context).accept!(mode: mode, parts: parts)[:parts]
  end

  def run_council(context, parts)
    Captain::Runtime::Council.new(context: context, graph: graph, account: nil, model: 'openai/gpt-6-luna').tap do |council|
      allow(council).to receive(:fresh_actor) { |id| actors[id] }
    end.run(parts)
  end

  def operations
    session.read.fetch('operations').values
  end

  before do
    session.update_routing(actor_id: current_id)
    allow(Captain::Runtime::ChatFactory).to receive(:build) do |agent:, context_wrapper:, **|
      chats.fetch(agent.name).tap { |chat| chat.context_wrapper = context_wrapper }
    end
    allow(Captain::AssistantSafetyPreferences).to receive(:for).and_return({})
    allow(Captain::Runtime::CouncilEditor).to receive(:new).and_return(editor)
    allow(editor).to receive(:edit) do |parts:, **|
      Captain::Runtime::CouncilEditor::Outcome.new(reply: parts.pluck('text').join(' '))
    end
    # The examples share one connection with their transaction, so no thread opens a transaction of its own.
    allow(described_class).to receive(:parallel?).and_return(false)
  end

  after { Current.reset }

  let(:first_message) { 'Запишите меня к терапевту на 14 октября в 10:00 и сколько стоит МРТ' }
  let(:first_context) { new_context('request-1', first_message) }
  let(:first_parts) do
    plan_for(first_context, [{ fragment: 'Запишите меня к терапевту на 14 октября в 10:00', patient: 'Анна', executor_agent_id: writer_id },
                             { fragment: 'Сколько стоит МРТ?', patient: 'Анна', executor_agent_id: reader_id }])
  end

  it 'books in the run of its owner, tells it in the one reply and leaves the conversation with the agent that holds it' do
    writer_chat.script(books('Анна, 14 октября'))
    reader_chat.script(looks_up_the_price)
    revision = session.read['routing_revision']

    reply = run_council(first_context, first_parts)

    booked = first_parts.first
    expect(reply).to eq('Вы записаны к терапевту Иванову на 14 октября в 10:00. МРТ стоит 15000 тенге.')
    expect(booking.calls).to eq(['Анна, 14 октября'])
    expect(operations).to contain_exactly(
      include('status' => 'finished', 'scope' => "part:#{booked['id']}:v1", 'actor_id' => writer_id, 'outcome' => 'success')
    )
    expect(session.read['current_assistant_id']).to eq(current_id)
    expect(session.read['routing_revision']).to eq(revision)
    expect(session.read['parts'].pluck('state', 'acted')).to eq([['done', true], ['answered', false]])
    expect(session.read['parts'].first['summary']).to eq('Вы записаны к терапевту Иванову на 14 октября в 10:00.')
    expect(first_context[:captain_v2_completed_actions]).to eq(['create_appointment'])
    expect(first_context[:state][:assistant_id]).to eq(current_id)
    expect(first_context).not_to have_key(:council_handoff)
  end

  it 'lets the same owner finish the part when the customer answers its question, as the next version, and books once' do
    writer_chat.script(asks('На какое время вас записать?'))
    reader_chat.script(looks_up_the_price)
    first_reply = run_council(first_context, first_parts)
    expect(first_reply).to eq('На какое время вас записать? МРТ стоит 15000 тенге.')
    expect(booking.calls).to be_empty
    waiting = session.read['parts'].first
    expect(waiting).to include('state' => 'waiting_customer', 'missing_fields' => ['На какое время вас записать?'])

    second_context = new_context('request-2', 'давайте в 11')
    second_parts = plan_for(second_context, [{ fragment: 'давайте в 11', executor_agent_id: current_id, link_part_id: waiting['id'], link_action: 'answer' }])
    writer_chat.script(books('Анна, 11:00', text: 'Вы записаны к терапевту Иванову на 14 октября в 11:00.'))
    second_reply = run_council(second_context, second_parts)

    expect(second_parts.sole).to include('id' => waiting['id'], 'version' => 2, 'executor_agent_id' => writer_id)
    expect(second_reply).to eq('Вы записаны к терапевту Иванову на 14 октября в 11:00.')
    expect(booking.calls).to eq(['Анна, 11:00'])
    expect(operations).to contain_exactly(include('scope' => "part:#{waiting['id']}:v2", 'actor_id' => writer_id, 'outcome' => 'success'))
    expect(session.read['current_assistant_id']).to eq(current_id)
    expect(second_context[:state][:assistant_id]).to eq(current_id)
    expect(session.read['parts'].first).to include('version' => 2, 'state' => 'done', 'acted' => true, 'prior_summary' => 'На какое время вас записать?')
  end

  it 'does not book again when the job is retried after the booking: the part is replayed' do
    writer_chat.script(books('Анна, 14 октября'))
    reader_chat.script(looks_up_the_price)
    reply = run_council(first_context, first_parts)

    retried_context = new_context('request-1', first_message)
    replayed = run_council(retried_context, first_parts)

    expect(replayed).to eq(reply)
    expect(booking.calls.size).to eq(1)
    expect(operations.size).to eq(1)
  end

  it 'keeps the booking when the customer writes again while the part runs, and reports it with the next reply' do
    writer_chat.script(lambda do |chat|
      Captain::Runtime::ToolWrapper.new(booking, chat.context_wrapper).call(title: 'Анна, 14 октября')
      raise Captain::Conversation::ControlGenerationStaleError, 'a newer message arrived'
    end)
    reader_chat.script(looks_up_the_price)

    expect { run_council(first_context, first_parts) }.to raise_error(Captain::Conversation::ControlGenerationStaleError)

    booked = session.read['parts'].first
    expect(booked).to include('state' => 'done', 'acted' => true)
    expect(booked['summary']).to include('create_appointment')
    expect(Captain::Runtime::PartRegistry.undelivered_outcomes(session.read['parts']).pluck('id')).to eq([booked['id']])
    next_prompt = Captain::Runtime::CoordinationPrompt.render(new_context('request-2', 'Ну что?').merge(agent_tasks: []))
    expect(next_prompt).to include('Completed actions the customer has not been told about (data): ', booked['id'])
  end

  it 'treats a business answer as an answer: the owner says the time is taken, and may book another time in the next version' do
    booking.result = JSON.generate(success: false, reason: 'time_taken')
    writer_chat.script(lambda do |chat|
      Captain::Runtime::ToolWrapper.new(booking, chat.context_wrapper).call(title: 'Анна, 10:00')
      answer('Это время занято. На какое время вас записать?', status: 'needs_information', questions: ['На какое время вас записать?'],
                                                                sources: ['create_appointment'])
    end)
    reader_chat.script(looks_up_the_price)
    run_council(first_context, first_parts)

    waiting = session.read['parts'].first
    expect(waiting).to include('state' => 'waiting_customer', 'acted' => false)
    expect(operations).to contain_exactly(include('scope' => "part:#{waiting['id']}:v1", 'outcome' => 'not_executed'))
    expect(first_context).not_to have_key(:technical_failure)
    expect(first_context).not_to have_key(:council_handoff)

    booking.result = nil
    second_context = new_context('request-2', 'давайте в 11')
    second_parts = plan_for(second_context, [{ fragment: 'давайте в 11', executor_agent_id: current_id, link_part_id: waiting['id'], link_action: 'answer' }])
    writer_chat.script(books('Анна, 11:00', text: 'Вы записаны на 11:00.'))

    expect(run_council(second_context, second_parts)).to eq('Вы записаны на 11:00.')
    expect(booking.calls).to eq(['Анна, 10:00', 'Анна, 11:00'])
  end

  it 'does not mention a part whose tool failed technically: the other part is answered and staff take over after the reply' do
    booking.result = Captain::ToolResult.failure(error: 'Provider did not answer', retryable: false,
                                                 audit: { failure_stage: 'tool_execution', failure_reason: 'provider_unavailable' })
    writer_chat.script(lambda do |chat|
      Captain::Runtime::ToolWrapper.new(booking, chat.context_wrapper).call(title: 'Анна, 14 октября')
    end)
    reader_chat.script(looks_up_the_price)

    reply = run_council(first_context, first_parts)

    failed = session.read['parts'].first
    expect(reply).to eq('МРТ стоит 15000 тенге.')
    expect(failed['state']).to eq('unknown')
    expect(first_context[:council_handoff]).to include(
      reason: 'council_technical_failure', technical: true,
      failures: [include('tool' => 'create_appointment', 'kind' => 'technical', 'stage' => 'tool_execution', 'reason' => 'provider_unavailable')]
    )
    expect(operations).to contain_exactly(include('outcome' => 'unknown'))
    expect(booking.calls.size).to eq(1)
  end

  it 'ends the whole run as a technical failure when every part of the council failed' do
    failure = Captain::ToolResult.failure(error: 'Provider did not answer', retryable: false)
    booking.result = failure
    writer_chat.script(lambda do |chat|
      Captain::Runtime::ToolWrapper.new(booking, chat.context_wrapper).call(title: 'Анна, 14 октября')
    end)
    broken_price = Captain::ToolResult.failure(error: 'Price list is down', retryable: false)
    allow(price).to receive(:perform).and_return(broken_price)
    reader_chat.script(->(chat) { Captain::Runtime::ToolWrapper.new(price, chat.context_wrapper).call({}) })

    reply = run_council(first_context, first_parts)

    expect(reply).to eq('')
    expect(first_context[:technical_failure]).to include('tool' => 'create_appointment', 'parts' => 2)
  end
end
# rubocop:enable Lint/ConstantDefinitionInBlock