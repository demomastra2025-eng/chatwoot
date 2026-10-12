# frozen_string_literal: true

require 'rails_helper'

class RunnerTaskFinalizationSpecChat
  attr_accessor :context_wrapper
  attr_reader :messages, :requests

  def initialize
    @messages = []
    @requests = []
    @responses = []
  end

  def respond_with(*responses)
    @responses.concat(responses)
  end

  def add_message(message_or_attributes)
    message = if message_or_attributes.is_a?(RubyLLM::Message)
                message_or_attributes
              else
                RubyLLM::Message.new(message_or_attributes)
              end
    @messages << message
    message
  end

  def ask(input)
    @requests << :ask
    add_message(role: :user, content: input)
    next_response
  end

  def complete
    @requests << :complete
    next_response
  end

  private

  def next_response
    step = @responses.shift || raise('Unexpected model continuation')
    response = step.respond_to?(:call) ? step.call(context_wrapper.context) : step
    add_message(response) if response.is_a?(RubyLLM::Message)
    response
  end
end

RSpec.describe Captain::Runtime::Runner do
  subject(:runner) { described_class.new }

  let(:input) { 'Move my appointment and prepare a quote.' }
  let(:agent) { Captain::Runtime::Agent.new(name: 'assistant_92', model: 'gpt-4.1-mini') }
  let(:chat) { RunnerTaskFinalizationSpecChat.new }
  let(:chats) { { agent.name => chat } }
  let(:registry) { { agent.name => agent } }
  # The message already has its accepted request plan: these examples cover task finalization only.
  let(:context) do
    {
      state: { assistant_id: 92 },
      part_plan_accepted: true,
      agent_graph: [{ id: 92, name: 'Scheduling' }, { id: 91, name: 'Quotes' }],
      agent_tasks: [
        task('appointment-task', owner: 92, status: 'active'),
        task('quote-task', owner: 91, status: 'waiting')
      ]
    }
  end

  before do
    allow(Captain::Runtime::ChatFactory).to receive(:build) do |agent:, context_wrapper:, **|
      agent.context_preparer&.call(context_wrapper)
      chats.fetch(agent.name).tap do |built_chat|
        built_chat.context_wrapper = context_wrapper
        Captain::Runtime::HistoryRestorer.restore(built_chat, context_wrapper.context[:conversation_history])
      end
    end
  end

  def task(id, owner:, status:)
    { 'id' => id, 'title' => id, 'assistant_id' => owner, 'status' => status, 'result' => nil }
  end

  def reply(content)
    RubyLLM::Message.new(role: :assistant, content: content)
  end

  def reminders(target_chat = chat)
    target_chat.messages.select { |message| message.role == :system }
  end

  def run_with(**options)
    runner.run(agent, input, context: context, registry: registry, **options)
  end

  def expect_initial_ask
    expect(Llm::Runtime).to receive(:ask).with(
      chat, input, model: agent.model,
      observability: hash_including(assistant_id: 92, current_agent: agent.name)
    ).once.and_call_original
  end

  it 'continues an active task and returns only the corrected final result' do
    chat.respond_with(lambda do |_current_context|
      call_params = Captain::Runtime::HistoryRestorer.build_message_params({
        role: :assistant, content: '',
        tool_calls: [{ id: 'move_once', name: 'update_appointment', arguments: { appointment_id: 'synthetic' } }]
      })
      chat.add_message(call_params)
      chat.add_message(role: :tool, content: 'Appointment moved once', tool_call_id: 'move_once')
      reply('Premature draft')
    end, lambda do |current_context|
      Captain::Runtime::TaskQueue.new(current_context).update(
        id: 'appointment-task', status: 'completed', result: 'Appointment moved once'
      )
      reply('Appointment moved; please provide the quote amount.')
    end)
    expect_initial_ask
    expect(Llm::Runtime).to receive(:complete).with(
      chat, model: agent.model,
      observability: hash_including(assistant_id: 92, current_agent: agent.name)
    ).once.and_call_original

    result = run_with

    expect(result).to be_success
    expect(result.output).to eq('Appointment moved; please provide the quote amount.')
    expect(result.messages.map { |message| message[:content] }).not_to include('Premature draft')
    expect(result.messages).to include(
      hash_including(role: :assistant, tool_calls: [hash_including(id: 'move_once', name: 'update_appointment')]),
      hash_including(role: :tool, content: 'Appointment moved once', tool_call_id: 'move_once')
    )
    expect(result.context[:agent_tasks].map { |item| item['status'] }).to eq(%w[completed waiting])
    expect(reminders.size).to eq(1)
    expect(reminders.first.content).to include('appointment-task', 'quote-task', 'active', 'waiting')
    expect(chat.requests).to eq(%i[ask complete])
    expect(chat.messages.select { |message| message.role == :user }.map(&:content)).to eq([input])
    expect(context[:agent_tasks].first['status']).to eq('active')
  end

  it 'does not finalize while another assigned agent still has awaiting work' do
    context[:agent_tasks].first['status'] = 'completed'
    context[:agent_tasks].last['status'] = 'awaiting'
    target = Captain::Runtime::Agent.new(name: 'assistant_91', model: 'gpt-4.1-nano')
    target.context_preparer = lambda do |wrapper|
      wrapper.context[:state][:assistant_id] = 91
      Captain::Runtime::TaskQueue.new(wrapper.context).on_handoff
    end
    target_chat = RunnerTaskFinalizationSpecChat.new
    chats[target.name] = target_chat
    registry[target.name] = target
    chat.respond_with(reply('Appointment done; nothing else to do.'), lambda do |current_context|
      current_context[:pending_handoff] = { target_agent: target.name }
      RubyLLM::Tool::Halt.new('Internal transfer')
    end)
    target_chat.respond_with(lambda do |current_context|
      Captain::Runtime::TaskQueue.new(current_context).update(id: 'quote-task', status: 'waiting', result: 'Customer will provide amount')
      reply('Appointment done; what amount should the quote use?')
    end)
    expect_initial_ask
    expect(Llm::Runtime).to receive(:complete).with(
      chat, model: agent.model, observability: hash_including(assistant_id: 92)
    ).once.ordered.and_call_original
    expect(Llm::Runtime).to receive(:complete).with(
      target_chat, model: target.model, observability: hash_including(assistant_id: 91, current_agent: target.name)
    ).once.ordered.and_call_original

    result = run_with

    expect(result).to be_success
    expect(result.output).to eq('Appointment done; what amount should the quote use?')
    expect(result.context[:current_agent]).to eq(target.name)
    expect(result.context[:agent_tasks].map { |item| item['status'] }).to eq(%w[completed waiting])
    expect(reminders.size).to eq(1)
    expect(reminders.first.content).to include('quote-task', 'awaiting')
    expect(reminders(target_chat)).to be_empty
    expect(target_chat.requests).to eq([:complete])
  end

  it 'finalizes immediately when all tasks are waiting for customer facts' do
    context[:agent_tasks].each { |item| item['status'] = 'waiting' }
    chat.respond_with(reply('Please provide the new date and quote amount.'))
    expect_initial_ask
    expect(Llm::Runtime).not_to receive(:complete)

    result = run_with

    expect(result).to be_success
    expect(result.output).to eq('Please provide the new date and quote amount.')
    expect(result.context[:agent_tasks].map { |item| item['status'] }).to eq(%w[waiting waiting])
    expect(reminders).to be_empty
  end

  it 'does not retry completed, failed or cancelled tasks' do
    context[:agent_tasks] = %w[completed failed cancelled].map.with_index do |status, index|
      task("settled-#{index}", owner: 92, status: status)
    end
    chat.respond_with(reply('Here are the verified outcomes.'))
    expect_initial_ask
    expect(Llm::Runtime).not_to receive(:complete)

    result = run_with

    expect(result).to be_success
    expect(result.output).to eq('Here are the verified outcomes.')
    expect(result.context[:agent_tasks].map { |item| item['status'] }).to eq(%w[completed failed cancelled])
    expect(reminders).to be_empty
  end

  it 'does not add a queue or continuation to a request without tasks' do
    context.delete(:agent_tasks)
    chat.respond_with(reply('The clinic opens at nine.'))
    expect_initial_ask
    expect(Llm::Runtime).not_to receive(:complete)

    result = run_with

    expect(result).to be_success
    expect(result.output).to eq('The clinic opens at nine.')
    expect(result.context).not_to have_key(:agent_tasks)
    expect(reminders).to be_empty
  end

  it 'skips queue repair during a finalization-only history continuation' do
    context[:conversation_history] = [{ role: :user, content: input }]
    chat.respond_with(reply('A tool limit stopped further work.'))
    expect(Llm::Runtime).not_to receive(:ask)
    expect(Llm::Runtime).to receive(:complete).with(
      chat, model: agent.model, observability: hash_including(assistant_id: 92)
    ).once.and_call_original

    result = run_with(finalization_only: true, continue_from_history: true)

    expect(result).to be_success
    expect(result.output).to eq('A tool limit stopped further work.')
    expect(result.context[:agent_tasks].first['status']).to eq('active')
    expect(chat.requests).to eq([:complete])
    expect(reminders).to be_empty
  end

  describe 'a graph run without a request plan' do
    before do
      context.delete(:part_plan_accepted)
      context[:agent_tasks] = []
    end

    it 'answers a plain reply in one model call, without asking for a plan' do
      chat.respond_with(reply('The clinic opens at nine.'))
      expect_initial_ask
      expect(Llm::Runtime).not_to receive(:complete)

      result = run_with

      expect(result).to be_success
      expect(result.output).to eq('The clinic opens at nine.')
      expect(chat.requests).to eq([:ask])
      expect(reminders).to be_empty
      expect(result.context.slice(:part_plan, :part_plan_accepted)).to be_empty
      expect(result.messages.map { |message| message[:content] }).to include('The clinic opens at nine.')
    end

    it 'answers after read-only tool calls without asking for a plan' do
      chat.respond_with(lambda do |_current_context|
        call_params = Captain::Runtime::HistoryRestorer.build_message_params(
          role: :assistant, content: '',
          tool_calls: [{ id: 'lookup_once', name: 'search_scheduling_services', arguments: { query: 'synthetic' } }]
        )
        chat.add_message(call_params)
        chat.add_message(role: :tool, content: 'Exactly one service matches', tool_call_id: 'lookup_once')
        reply('The synthetic service costs 5000.')
      end)
      expect_initial_ask
      expect(Llm::Runtime).not_to receive(:complete)

      result = run_with

      expect(result).to be_success
      expect(result.output).to eq('The synthetic service costs 5000.')
      expect(chat.requests).to eq([:ask])
      expect(reminders).to be_empty
    end

    describe 'in a single-agent setup' do
      before do
        context[:state][:captain_runtime] = {}
        context[:agent_graph] = [{ id: 92, key: 'assistant_92', name: 'Intermedical — DEV Test', description: 'Клиника' }]
      end

      def plan_with(**arguments)
        Captain::Runtime::ToolWrapper.new(Captain::Runtime::PartPlanTool.new, chat.context_wrapper).call(arguments)
      end

      it 'delivers a greeting in one model call without any plan' do
        chat.respond_with(reply('Здравствуйте! Чем могу помочь?'))
        expect_initial_ask
        expect(Llm::Runtime).not_to receive(:complete)

        result = run_with

        expect(result).to be_success
        expect(result.output).to eq('Здравствуйте! Чем могу помочь?')
        expect(chat.requests).to eq([:ask])
        expect(result.context).not_to include(:part_plan, :part_plan_refused)
      end

      it 'delivers a plain reply after a plan_request that named an agent which does not exist' do
        failed = nil
        chat.respond_with(lambda do |_current_context|
          failed = plan_with(mode: 'handoff', parts: [{ fragment: 'Анализы', executor: 'Лаборатория' }])
          reply('Анализы можно сдать в клинике ежедневно.')
        end)
        expect_initial_ask
        expect(Llm::Runtime).not_to receive(:complete)

        result = run_with

        expect(failed).to start_with('ERROR: ').and include('"retryable":true')
        expect(result).to be_success
        expect(result.output).to eq('Анализы можно сдать в клинике ежедневно.')
        expect(chat.requests).to eq([:ask])
        expect(result.context).not_to include(:part_plan_accepted, :part_plan_refused)
      end

      it 'delivers the reply after an agreed human handoff was first tried as a plan_request handoff, even when repeated' do
        failures = []
        chat.respond_with(lambda do |_current_context|
          failures << plan_with(mode: 'handoff', parts: [{ fragment: 'Соедините с оператором' }])
          failures << plan_with(mode: 'handoff', parts: [{ fragment: 'Соедините с оператором', executor: 'Intermedical — DEV Test' }])
          failures << plan_with(mode: 'handoff', parts: [{ fragment: 'Соедините с оператором' }])
          reply('Уточните, пожалуйста, чем помочь.')
        end)
        expect_initial_ask
        expect(Llm::Runtime).not_to receive(:complete)

        result = run_with

        expect(failures).to all(start_with('ERROR: ').and(include('"retryable":true', 'call the handoff tool, not plan_request')))
        expect(result).to be_success
        expect(result.output).to eq('Уточните, пожалуйста, чем помочь.')
        expect(result.context).not_to include(Captain::Runtime::ToolWrapper::TERMINAL_TOOL_STOP_KEY, :part_plan_accepted, :part_plan_refused)
      end

      it 'keeps the human handoff of the model, which follows the rejected plan, intact' do
        chat.respond_with(lambda do |_current_context|
          plan_with(mode: 'handoff', parts: [{ fragment: 'Соедините с оператором' }])
          RubyLLM::Tool::Halt.new('conversation_handoff')
        end)
        expect_initial_ask
        expect(Llm::Runtime).not_to receive(:complete)

        result = run_with

        expect(result).to be_success
        expect(result.output).to eq('conversation_handoff')
        expect(result.context).not_to include(Captain::Runtime::ToolWrapper::TERMINAL_TOOL_STOP_KEY, :part_plan_accepted, :transfer_guarded)
        expect(reminders).to be_empty
      end

      it 'accepts a guessed executor number as the agent itself and delivers the reply of the planned message' do
        chat.respond_with(lambda do |_current_context|
          plan_with(mode: 'answer_myself', parts: [{ fragment: 'Записать на приём', executor_agent_id: 1 }])
          reply('Выберите удобное время.')
        end)
        expect_initial_ask
        expect(Llm::Runtime).not_to receive(:complete)

        result = run_with

        expect(result).to be_success
        expect(result.output).to eq('Выберите удобное время.')
        expect(result.context[:part_plan][:parts].sole).to include('executor_agent_id' => 92)
        expect(chat.requests).to eq([:ask])
      end
    end

    describe 'with a proposed operation waiting for the customer' do
      let(:pending_part) do
        { 'id' => 'pending-part', 'state' => 'waiting_confirmation', 'fragment' => 'Book the synthetic scan',
          'proposed_operation' => { 'type' => 'create_appointment', 'params' => { 'service_id' => 1 } } }
      end

      before { context[:parts] = [pending_part] }

      it 'withholds a plain answer and asks for the plan that confirms or cancels the operation' do
        chat.respond_with(reply('Booked.'), lambda do |current_context|
          current_context[:part_plan_accepted] = true
          reply('The synthetic scan is confirmed.')
        end)
        expect_initial_ask
        expect(Llm::Runtime).to receive(:complete).once.and_call_original

        result = run_with

        expect(result).to be_success
        expect(result.output).to eq('The synthetic scan is confirmed.')
        expect(chat.requests).to eq(%i[ask complete])
        expect(reminders.map(&:content)).to eq(['Call plan_request for this message before replying.'])
        expect(result.messages.map { |message| message[:content] }).not_to include('Booked.')
      end

      it 'answers with the open requests when the model still gives no plan' do
        chat.respond_with(reply('Booked.'), reply('Booked, really.'))
        expect_initial_ask
        expect(Llm::Runtime).to receive(:complete).once.and_call_original

        result = run_with

        expect(result.output[:response]).to start_with(I18n.t('captain.coordination.unfinished', locale: :ru))
        expect(result.output[:response]).to include('Book the synthetic scan')
        expect(result.messages.map { |message| message[:content] }).not_to include('Booked.', 'Booked, really.')
      end

      it 'carries out the proposal only through the confirmed operations once the answer is planned as a confirmation' do
        context[:parts] = [pending_part.merge('executor_agent_id' => 92, 'version' => 1)]
        executed = []
        operations = instance_double(Captain::Runtime::ConfirmedOperations)
        allow(Captain::Runtime::ConfirmedOperations).to receive(:new).and_return(operations)
        allow(operations).to receive(:run) do |parts|
          executed.concat(parts)
          'The synthetic scan is booked.'
        end
        chat.respond_with(reply('Booked.'), lambda do |current_context|
          Captain::Runtime::PartRegistry.new(current_context).accept!(
            mode: 'answer_myself',
            parts: [{ fragment: 'yes', executor_agent_id: 92, link_part_id: 'pending-part', link_action: 'confirmation' }]
          )
          reply('Text that the confirmed operation replaces.')
        end)
        expect_initial_ask
        expect(Llm::Runtime).to receive(:complete).once.and_call_original

        result = run_with

        expect(result.output).to eq({ response: 'The synthetic scan is booked.', reasoning: '' })
        expect(executed.map { |part| part.slice('id', 'link_action', 'proposed_operation') }).to eq(
          [{ 'id' => 'pending-part', 'link_action' => 'confirmation', 'proposed_operation' => pending_part['proposed_operation'] }]
        )
        expect(reminders.map(&:content)).to eq(['Call plan_request for this message before replying.'])
      end

      it 'does not ask again once the message is planned' do
        context[:part_plan_accepted] = true
        chat.respond_with(reply('Nothing to confirm yet.'))
        expect_initial_ask
        expect(Llm::Runtime).not_to receive(:complete)

        expect(run_with.output).to eq('Nothing to confirm yet.')
      end

      it 'does not ask for a plan in a consultation, which cannot call plan_request' do
        context[:consult_mode] = true
        chat.respond_with(reply('Consultation fragment.'))
        expect_initial_ask
        expect(Llm::Runtime).not_to receive(:complete)

        expect(run_with.output).to eq('Consultation fragment.')
      end

      it 'does not ask for a plan for a part that holds no proposed operation' do
        context[:parts] = [pending_part.merge('state' => 'waiting_customer', 'proposed_operation' => nil)]
        chat.respond_with(reply('The clinic opens at nine.'))
        expect_initial_ask
        expect(Llm::Runtime).not_to receive(:complete)

        expect(run_with.output).to eq('The clinic opens at nine.')
      end
    end

    it 'accepts the reply after the agent\'s own data-changing call without asking for a plan' do
      chat.respond_with(lambda do |_current_context|
        call_params = Captain::Runtime::HistoryRestorer.build_message_params(
          role: :assistant, content: '',
          tool_calls: [{ id: 'book_once', name: 'create_appointment', arguments: { service_id: 1 } }]
        )
        chat.add_message(call_params)
        chat.add_message(role: :tool, content: 'Appointment created', tool_call_id: 'book_once')
        reply('You are booked for the synthetic scan.')
      end)
      expect_initial_ask
      expect(Llm::Runtime).not_to receive(:complete)

      result = run_with

      expect(result).to be_success
      expect(result.output).to eq('You are booked for the synthetic scan.')
      expect(chat.requests).to eq([:ask])
      expect(reminders).to be_empty
      expect(result.context.slice(:part_plan, :part_plan_accepted)).to be_empty
    end

    it 'does not accept a plain reply right after a transfer to another agent was refused for lack of a plan' do
      chat.respond_with(lambda do |current_context|
        current_context[:part_plan_refused] = true
        reply('I have passed you to a specialist.')
      end, lambda do |current_context|
        current_context[:part_plan_accepted] = true
        reply('I could not transfer you yet; what do you need?')
      end)
      expect_initial_ask
      expect(Llm::Runtime).to receive(:complete).once.and_call_original

      result = run_with

      expect(result.output).to eq('I could not transfer you yet; what do you need?')
      expect(chat.requests).to eq(%i[ask complete])
      expect(reminders.map(&:content)).to eq(['Call plan_request for this message before replying.'])
      expect(result.messages.map { |message| message[:content] }).not_to include('I have passed you to a specialist.')
    end

    describe 'a lone agent' do
      before { context[:agent_graph] = [{ id: 92, name: 'Scheduling' }] }

      it 'is not asked for a plan it cannot make, even when an old proposal still waits for the customer' do
        context[:parts] = [{ 'id' => 'old-part', 'state' => 'waiting_confirmation', 'fragment' => 'Book the synthetic scan',
                             'proposed_operation' => { 'type' => 'create_appointment', 'params' => { 'service_id' => 1 } } }]
        chat.respond_with(reply('Yes, I will book it now.'))
        expect_initial_ask
        expect(Llm::Runtime).not_to receive(:complete)

        expect(run_with.output).to eq('Yes, I will book it now.')
      end
    end
  end

  it 'bounds noncompliance to two continuations and returns no final reply' do
    chat.respond_with(reply('Premature first draft'), reply('Premature second draft'), reply('Premature third draft'))
    expect_initial_ask
    expect(Llm::Runtime).to receive(:complete).exactly(2).times.and_call_original

    result = run_with

    expect(result).to be_failed
    expect(result.output).to be_nil
    expect(result.error).to be_a(described_class::UnresolvedTasksError)
    expect(result.messages.none? { |message| message[:role] == :assistant }).to be(true)
    expect(result.context[:agent_tasks].map { |item| item['status'] }).to eq(%w[active waiting])
    expect(chat.requests).to eq(%i[ask complete complete])
    expect(reminders.size).to eq(2)
  end

  it 'does not reset the two-repair budget when execution hands off to another model' do
    context[:agent_tasks].last['status'] = 'awaiting'
    target = Captain::Runtime::Agent.new(name: 'assistant_91', model: 'gpt-4.1-nano')
    target.context_preparer = lambda do |wrapper|
      wrapper.context[:state][:assistant_id] = 91
      Captain::Runtime::TaskQueue.new(wrapper.context).on_handoff
    end
    target_chat = RunnerTaskFinalizationSpecChat.new
    chats[target.name] = target_chat
    registry[target.name] = target
    chat.respond_with(reply('Premature scheduling draft'), lambda do |current_context|
      Captain::Runtime::TaskQueue.new(current_context).update(id: 'appointment-task', status: 'waiting', result: 'Customer clarification needed')
      current_context[:pending_handoff] = { target_agent: target.name }
      RubyLLM::Tool::Halt.new('Internal transfer')
    end)
    target_chat.respond_with(reply('Premature quote draft'), reply('Another premature quote draft'))
    expect_initial_ask
    expect(Llm::Runtime).to receive(:complete).with(
      chat, model: agent.model, observability: hash_including(assistant_id: 92)
    ).once.and_call_original
    expect(Llm::Runtime).to receive(:complete).with(
      target_chat, model: target.model, observability: hash_including(assistant_id: 91, current_agent: target.name)
    ).exactly(2).times.and_call_original

    result = run_with

    expect(result.output).to be_nil
    expect(result.error).to be_a(described_class::UnresolvedTasksError)
    expect(result.context[:current_agent]).to eq(target.name)
    expect(result.context[:agent_tasks].map { |item| item['status'] }).to eq(%w[waiting active])
    expect(chat.requests).to eq(%i[ask complete])
    expect(target_chat.requests).to eq(%i[complete complete])
    expect(reminders.size + reminders(target_chat).size).to eq(2)
  end

  it 'preserves a human handoff Halt even with an active task' do
    chat.respond_with(RubyLLM::Tool::Halt.new('conversation_handoff'))
    expect_initial_ask
    expect(Llm::Runtime).not_to receive(:complete)

    result = run_with

    expect(result).to be_success
    expect(result.output).to eq('conversation_handoff')
    expect(result.context[:agent_tasks].first['status']).to eq('active')
    expect(reminders).to be_empty
  end

  it 'preserves a terminal tool stop instead of trying to settle tasks after a Halt' do
    terminal_result = Captain::ToolResult.failure(
      error: 'Tool request limit reached', retryable: false, audit: { failure_reason: 'tool_request_limit' }
    )
    context[Captain::Runtime::ToolWrapper::TERMINAL_TOOL_STOP_KEY] = { tool_name: 'search_deals', result: terminal_result }
    chat.respond_with(RubyLLM::Tool::Halt.new(Captain::ToolResult.render(terminal_result)))
    expect_initial_ask
    expect(Llm::Runtime).not_to receive(:complete)

    result = run_with

    expect(result.output).to be_nil
    expect(result.error).to be_a(described_class::ToolLoopStopped)
    expect(result.error.message).to eq('Tool request limit reached')
    expect(result.context[:agent_tasks].first['status']).to eq('active')
    expect(reminders).to be_empty
  end
end
