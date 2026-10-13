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
        expect(result.context).not_to include(:part_plan)
      end

      it 'delivers a plain reply after a plan_request that named an agent which does not exist' do
        failed = nil
        chat.respond_with(lambda do |_current_context|
          failed = plan_with(mode: 'council', parts: [{ fragment: 'Анализы', executor: 'Лаборатория' }])
          reply('Анализы можно сдать в клинике ежедневно.')
        end)
        expect_initial_ask
        expect(Llm::Runtime).not_to receive(:complete)

        result = run_with

        expect(failed).to start_with('ERROR: ').and include('"retryable":true')
        expect(result).to be_success
        expect(result.output).to eq('Анализы можно сдать в клинике ежедневно.')
        expect(chat.requests).to eq([:ask])
        expect(result.context).not_to include(:part_plan_accepted)
      end

      it 'delivers the reply after an agreed human handoff was first tried as a plan_request, even when repeated' do
        failures = []
        chat.respond_with(lambda do |_current_context|
          failures << plan_with(mode: 'council', parts: [{ fragment: 'Соедините с оператором' }])
          failures << plan_with(mode: 'council', parts: [{ fragment: 'Соедините с оператором', executor: 'Intermedical — DEV Test' }])
          failures << plan_with(mode: 'council', parts: [{ fragment: 'Соедините с оператором' }])
          reply('Уточните, пожалуйста, чем помочь.')
        end)
        expect_initial_ask
        expect(Llm::Runtime).not_to receive(:complete)

        result = run_with

        expect(failures).to all(start_with('ERROR: ').and(include('"retryable":true', 'Own work needs no plan: answer or use your tools.')))
        expect(result).to be_success
        expect(result.output).to eq('Уточните, пожалуйста, чем помочь.')
        expect(result.context).not_to include(Captain::Runtime::ToolWrapper::TERMINAL_TOOL_STOP_KEY, :part_plan_accepted)
      end

      it 'keeps the human handoff of the model, which follows the rejected plan, intact' do
        chat.respond_with(lambda do |_current_context|
          plan_with(mode: 'council', parts: [{ fragment: 'Соедините с оператором' }])
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

      it 'refuses a plan for its own work, and delivers the plain reply of the model' do
        failed = nil
        chat.respond_with(lambda do |_current_context|
          failed = plan_with(mode: 'council', parts: [{ fragment: 'Записать на приём' }, { fragment: 'Цена приёма' }])
          reply('Выберите удобное время.')
        end)
        expect_initial_ask
        expect(Llm::Runtime).not_to receive(:complete)

        result = run_with

        expect(failed).to start_with('ERROR: ').and include('"retryable":true', 'Own work needs no plan: answer or use your tools.')
        expect(result).to be_success
        expect(result.output).to eq('Выберите удобное время.')
        expect(result.context).not_to include(:part_plan, :part_plan_accepted)
        expect(chat.requests).to eq([:ask])
      end
    end

    describe 'with an open part of another agent that waits for the customer\'s answer' do
      let(:question) { 'На какое время вас записать?' }
      let(:waiting_part) do
        { 'id' => 'pending-part', 'version' => 1, 'state' => 'waiting_customer', 'executor_agent_id' => 91, 'fragment' => 'Book the synthetic scan',
          'missing_fields' => [question], 'delivered' => [{ 'message_id' => 7, 'content' => question }] }
      end

      before do
        context[:parts] = [waiting_part]
        context[:conversation_history] = [{ role: 'user', content: 'Запишите на МРТ' }, { role: 'assistant', content: question }]
      end

      it 'withholds a plain reply once and asks to plan the answer for the agent that asked, naming it' do
        chat.respond_with(reply('Записала.'), reply('Поняла вас.'))
        expect_initial_ask
        expect(Llm::Runtime).to receive(:complete).once.and_call_original

        result = run_with

        expect(result).to be_success
        expect(chat.requests).to eq(%i[ask complete])
        expect(reminders.map(&:content).sole).to include('An open part of Quotes waits for the customer\'s answer',
                                                         'call plan_request with mode council and ONLY that part linked',
                                                         'Otherwise reply normally')
        expect(result.messages.map { |message| message[:content] }).not_to include('Записала.')
      end

      it 'accepts the second plain reply, whatever it is, and never answers with a text of its own' do
        chat.respond_with(reply('Записала.'), reply('Давайте уточним время.'))
        expect_initial_ask
        expect(Llm::Runtime).to receive(:complete).once.and_call_original

        result = run_with

        expect(result.output).to eq('Давайте уточним время.')
        expect(result.error).to be_nil
      end

      it 'carries the answer to the agent that asked through a council of that one part, and the acting agent stays' do
        ran = []
        council = instance_double(Captain::Runtime::Council)
        allow(Captain::Runtime::Council).to receive(:new).and_return(council)
        allow(council).to receive(:run) do |parts|
          ran.concat(parts)
          'Вы записаны на 11:00.'
        end
        chat.respond_with(reply('Записала.'), lambda do |current_context|
          Captain::Runtime::PartRegistry.new(current_context).accept!(
            mode: 'council',
            parts: [{ fragment: 'давайте в 11', executor_agent_id: 91, link_part_id: 'pending-part', link_action: 'answer' }]
          )
          reply('Text that the council replaces.')
        end)
        expect_initial_ask
        expect(Llm::Runtime).to receive(:complete).once.and_call_original

        result = run_with

        expect(result.output).to eq({ response: 'Вы записаны на 11:00.', reasoning: '' })
        expect(ran.sole).to include('id' => 'pending-part', 'version' => 2, 'executor_agent_id' => 91, 'link_action' => 'answer')
        expect(Captain::Runtime::Council).to have_received(:new).with(hash_including(model: agent.model, callbacks: {}))
        expect(result.context[:state][:assistant_id]).to eq(92)
        expect(result.context[:current_agent]).to eq(agent.name)
        expect(result.context).not_to include(:active_part_id)
        expect(reminders.map(&:content).sole).to include('waits for the customer\'s answer')
      end

      it 'carries the language the owners of the parts wrote in with the council reply, for the logs; delivery reads the reply only' do
        allow(Captain::Runtime::Council).to receive(:new) do |context:, **|
          instance_double(Captain::Runtime::Council).tap do |council|
            allow(council).to receive(:run) do
              context[:council_patient_language] = 'Kazakh'
              'Сіз сағат 11:00-ге жазылдыңыз.'
            end
          end
        end
        chat.respond_with(reply('Записала.'), lambda do |current_context|
          Captain::Runtime::PartRegistry.new(current_context).accept!(
            mode: 'council',
            parts: [{ fragment: 'давайте в 11', executor_agent_id: 91, link_part_id: 'pending-part', link_action: 'answer' }]
          )
          reply('Text that the council replaces.')
        end)
        expect_initial_ask
        expect(Llm::Runtime).to receive(:complete).once.and_call_original

        result = run_with

        expect(result.output).to eq({ response: 'Сіз сағат 11:00-ге жазылдыңыз.', reasoning: '', patient_language: 'Kazakh' })
      end

      it 'sends nothing when no part of the council has a text of its own: the run is suppressed, not failed, and the runtime writes no sentence' do
        council = instance_double(Captain::Runtime::Council, run: '')
        allow(Captain::Runtime::Council).to receive(:new).and_return(council)
        chat.respond_with(reply('Записала.'), lambda do |current_context|
          Captain::Runtime::PartRegistry.new(current_context).accept!(
            mode: 'council',
            parts: [{ fragment: 'давайте в 11', executor_agent_id: 91, link_part_id: 'pending-part', link_action: 'answer' }]
          )
          reply('Text that the council replaces.')
        end)
        expect_initial_ask
        expect(Llm::Runtime).to receive(:complete).once.and_call_original

        result = run_with

        expect(result.error).to be_nil
        expect(result.output).to eq({ response: '', response_mode: 'suppress', reasoning: '' })
      end

      it 'does not run the council for the cancellation of a part that never acted: the agent answers it in its own words' do
        expect(Captain::Runtime::Council).not_to receive(:new)
        chat.respond_with(reply('Записала.'), lambda do |current_context|
          Captain::Runtime::PartRegistry.new(current_context).accept!(
            mode: 'council',
            parts: [{ fragment: 'не надо, отмените', executor_agent_id: 91, link_part_id: 'pending-part', link_action: 'cancellation' }]
          )
          reply('Хорошо, запись не оформляю.')
        end)
        expect_initial_ask
        expect(Llm::Runtime).to receive(:complete).once.and_call_original

        result = run_with

        expect(result.error).to be_nil
        expect(result.output).to eq('Хорошо, запись не оформляю.')
        expect(result.context[:part_plan][:parts].sole).to include('cancelled' => true, 'state' => 'done')
      end

      it 'ends a run of a live conversation that ran out of turns as a technical failure, never as a text for the customer' do
        context[:agent_session] = Object.new
        chat.respond_with(reply('Записала.'))
        expect_initial_ask

        result = run_with(max_turns: 1)

        expect(result.error).to be_a(described_class::TechnicalFailure)
        expect(result.error.message).to eq('Technical failure max_turns')
        expect(result.context[:technical_failure]).to eq('kind' => 'technical', 'reason' => 'max_turns')
        expect(result.output).to be_nil
      end

      it 'keeps the plain error for a run that ran out of turns without a live conversation' do
        chat.respond_with(reply('Записала.'))
        expect_initial_ask

        result = run_with(max_turns: 1)

        expect(result.error).to be_a(described_class::MaxTurnsExceeded)
        expect(result.context).not_to have_key(:technical_failure)
      end

      it 'does not ask again once the message is planned' do
        context[:part_plan_accepted] = true
        chat.respond_with(reply('Nothing to answer yet.'))
        expect_initial_ask
        expect(Llm::Runtime).not_to receive(:complete)

        expect(run_with.output).to eq('Nothing to answer yet.')
      end

      it 'does not ask for a plan in a council part, which cannot call plan_request' do
        context[:part_run] = true
        chat.respond_with(reply('Part of a council.'))
        expect_initial_ask
        expect(Llm::Runtime).not_to receive(:complete)

        expect(run_with.output).to eq('Part of a council.')
      end

      it 'does not ask for a plan for a part of the current agent, which continues it itself' do
        context[:parts] = [waiting_part.merge('executor_agent_id' => 92)]
        chat.respond_with(reply('The clinic opens at nine.'))
        expect_initial_ask
        expect(Llm::Runtime).not_to receive(:complete)

        expect(run_with.output).to eq('The clinic opens at nine.')
      end

      it 'does not ask for a plan when the question of the part is no longer the last thing the customer was told' do
        context[:conversation_history] << { role: 'user', content: 'Спасибо' } << { role: 'assistant', content: 'Пожалуйста!' }
        chat.respond_with(reply('The clinic opens at nine.'))
        expect_initial_ask
        expect(Llm::Runtime).not_to receive(:complete)

        expect(run_with.output).to eq('The clinic opens at nine.')
      end

      it 'does not ask for a plan for a part that does not wait for the customer' do
        context[:parts] = [waiting_part.merge('state' => 'done')]
        chat.respond_with(reply('The clinic opens at nine.'))
        expect_initial_ask
        expect(Llm::Runtime).not_to receive(:complete)

        expect(run_with.output).to eq('The clinic opens at nine.')
      end
    end

    describe 'a technical failure of a tool' do
      it 'ends the run with an error and no output, and leaves the record of the failure for the response builder' do
        failure = { 'tool' => 'create_appointment', 'kind' => 'technical', 'reason' => 'provider_unavailable' }
        chat.respond_with(lambda do |current_context|
          current_context[:technical_failure] = failure
          RubyLLM::Tool::Halt.new('A technical failure ended this run')
        end)
        expect_initial_ask
        expect(Llm::Runtime).not_to receive(:complete)

        result = run_with

        expect(result).to be_failed
        expect(result.output).to be_nil
        expect(result.error).to be_a(described_class::TechnicalFailure)
        expect(result.error.message).to eq('Technical failure create_appointment provider_unavailable')
        expect(result.context[:technical_failure]).to eq(failure)
      end

      it 'ends a council that has no reply left as the same error' do
        council = instance_double(Captain::Runtime::Council)
        allow(Captain::Runtime::Council).to receive(:new).and_return(council)
        allow(council).to receive(:run) do
          context_for_run = chat.context_wrapper.context
          context_for_run[:technical_failure] = { 'tool' => 'create_appointment', 'kind' => 'technical', 'parts' => 2 }
          ''
        end
        chat.respond_with(lambda do |current_context|
          Captain::Runtime::PartRegistry.new(current_context).accept!(
            mode: 'council', parts: [{ fragment: 'Запись', executor_agent_id: 91 }, { fragment: 'Цена', executor_agent_id: 92 }]
          )
          reply('Text that the council replaces.')
        end)
        context.delete(:part_plan_accepted)
        context[:agent_tasks] = []
        expect_initial_ask

        result = run_with

        expect(result.error).to be_a(described_class::TechnicalFailure)
        expect(result.output).to be_nil
      end

      it 'ends a repeated tool-call loop of a live conversation as a technical failure too, with no text for the customer' do
        context[:agent_session] = Object.new
        chat.respond_with(lambda do |current_context|
          current_context[Captain::Runtime::ToolWrapper::TERMINAL_TOOL_STOP_KEY] = { tool_name: 'x', result: { error: 'Tool request limit reached' } }
          RubyLLM::Tool::Halt.new('stop')
        end)
        expect_initial_ask

        result = run_with

        expect(result.error).to be_a(described_class::TechnicalFailure)
        expect(result.context[:technical_failure]).to eq('kind' => 'technical', 'reason' => 'tool_loop')
        expect(result.output).to be_nil
      end

      it 'keeps the stop of a repeated tool-call loop the generic error without a live conversation' do
        chat.respond_with(lambda do |current_context|
          current_context[Captain::Runtime::ToolWrapper::TERMINAL_TOOL_STOP_KEY] = { tool_name: 'x', result: { error: 'Tool request limit reached' } }
          RubyLLM::Tool::Halt.new('stop')
        end)
        expect_initial_ask

        result = run_with

        expect(result.error).to be_a(described_class::ToolLoopStopped)
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

    describe 'a transfer to one colleague' do
      let(:colleague) do
        Captain::Runtime::Agent.new(name: 'assistant_91', model: 'gpt-4.1-nano').tap do |agent|
          agent.assistant_id = 91
          agent.context_preparer = ->(wrapper) { wrapper.context[:state][:assistant_id] = 91 }
        end
      end
      let(:colleague_chat) { RunnerTaskFinalizationSpecChat.new }

      before do
        chats[colleague.name] = colleague_chat
        registry[colleague.name] = colleague
      end

      def transfer_to_colleague
        lambda do |current_context|
          current_context[:pending_handoff] = { target_agent: colleague }
          RubyLLM::Tool::Halt.new('')
        end
      end

      it 'hands the conversation over without any plan, and the colleague answers without being asked to plan' do
        chat.respond_with(transfer_to_colleague)
        colleague_chat.respond_with(reply('Анализы можно сдать в клинике ежедневно.'))
        expect_initial_ask
        expect(Llm::Runtime).to receive(:complete).with(
          colleague_chat, model: colleague.model, observability: hash_including(assistant_id: 91, current_agent: colleague.name)
        ).once.and_call_original

        result = run_with

        expect(result).to be_success
        expect(result.output).to eq('Анализы можно сдать в клинике ежедневно.')
        expect(result.context[:current_agent]).to eq(colleague.name)
        expect(result.context[:handoff_count]).to eq(1)
        expect(result.context).not_to include(:part_plan, :part_plan_accepted)
        expect(chat.requests).to eq([:ask])
        expect(colleague_chat.requests).to eq([:complete])
        expect(reminders).to be_empty
        expect(reminders(colleague_chat)).to be_empty
      end

      it 'gives the colleague the whole conversation, the customer message included' do
        chat.respond_with(transfer_to_colleague)
        colleague_chat.respond_with(reply('Готово.'))
        expect_initial_ask

        result = run_with

        expect(result.output).to eq('Готово.')
        expect(colleague_chat.messages.select { |message| message.role == :user }.map(&:content)).to eq([input])
      end

      it 'stops a transfer loop: the agent answers from what it knows, without a plan or a question' do
        chat.respond_with(lambda do |current_context|
          current_context[:transfer_guard_active] = true
          RubyLLM::Tool::Halt.new('')
        end, reply('Остальное уточнит администратор клиники.'))
        expect_initial_ask
        expect(Llm::Runtime).to receive(:complete).with(chat, model: agent.model, observability: hash_including(assistant_id: 92)).once.and_call_original

        result = run_with

        expect(result.output).to eq('Остальное уточнит администратор клиники.')
        expect(result.context[:current_agent]).to eq(agent.name)
        expect(result.context).to include(transfer_guarded: true)
        expect(result.context).not_to include(:part_plan, :part_plan_accepted, :pending_handoff)
        expect(reminders.map(&:content).sole).to eq(
          'You cannot transfer any more: handle the request with your own tools, or call handoff if only staff can do it.'
        )
        expect(colleague_chat.requests).to be_empty
      end

      it 'stops a third transfer of a run with the same note' do
        context[:handoff_count] = 2
        chat.respond_with(transfer_to_colleague, reply('Остальное уточнит администратор клиники.'))
        expect_initial_ask
        expect(Llm::Runtime).to receive(:complete).once.and_call_original

        result = run_with

        expect(result.output).to eq('Остальное уточнит администратор клиники.')
        expect(result.context).to include(transfer_guarded: true, handoff_count: 2)
        expect(reminders.map(&:content).sole).to eq(described_class::TRANSFER_GUARD_NOTE)
        expect(colleague_chat.requests).to be_empty
      end

      it 'counts only the transfers of the run as the limit: a pending return to the previous source is followed' do
        context[:handoff_count] = 1
        context[:previous_handoff_source_id] = 91
        chat.respond_with(transfer_to_colleague)
        colleague_chat.respond_with(reply('Готово.'))
        expect_initial_ask

        result = run_with

        expect(result.output).to eq('Готово.')
        expect(result.context).to include(handoff_count: 2)
        expect(result.context[:current_agent]).to eq(colleague.name)
        expect(result.context).not_to include(:transfer_guarded)
      end

      it 'runs the plan that was accepted in the same step before the transfer, so that the colleague is not asked and the council answers' do
        council = instance_double(Captain::Runtime::Council, run: 'Ответ совета.')
        allow(Captain::Runtime::Council).to receive(:new).and_return(council)
        chat.respond_with(lambda do |current_context|
          Captain::Runtime::PartRegistry.new(current_context).accept!(
            mode: 'council', parts: [{ fragment: 'Запись', executor_agent_id: 91 }, { fragment: 'Цена', executor_agent_id: 92 }]
          )
          current_context[:pending_handoff] = { target_agent: colleague }
          RubyLLM::Tool::Halt.new('')
        end)
        expect_initial_ask

        result = run_with

        expect(result.output).to eq({ response: 'Ответ совета.', reasoning: '' })
        expect(result.context[:current_agent]).to eq(agent.name)
        expect(result.context).not_to include(:handoff_count, :pending_handoff)
        expect(colleague_chat.requests).to be_empty
      end

      it 'gives the council the human handoff that the planner asked for in the same step, so that the answers of the other parts are sent' do
        council = instance_double(Captain::Runtime::Council, run: 'Повторный приём стоит 8000 тенге.')
        allow(Captain::Runtime::Council).to receive(:new).and_return(council)
        chat.respond_with(lambda do |current_context|
          Captain::Runtime::PartRegistry.new(current_context).accept!(
            mode: 'council', parts: [{ fragment: 'Готов ли ТТГ', executor_agent_id: 92 }, { fragment: 'Цена', executor_agent_id: 91 }]
          )
          current_context[:pending_human_handoff] = { reason: 'Result of the test', timestamp: Time.current }
          current_context[:captain_v2_handoff_tool_called] = true
          RubyLLM::Tool::Halt.new('')
        end)
        expect_initial_ask

        result = run_with

        expect(Captain::Runtime::Council).to have_received(:new).with(hash_including(staff_request: hash_including(reason: 'Result of the test')))
        expect(result.output).to eq({ response: 'Повторный приём стоит 8000 тенге.', reasoning: '' })
        expect(result.context).not_to include(:pending_human_handoff, :captain_v2_handoff_tool_called)
      end

      it 'asks the council for no staff when the planner did not call the handoff tool' do
        council = instance_double(Captain::Runtime::Council, run: 'Ответ совета.')
        allow(Captain::Runtime::Council).to receive(:new).and_return(council)
        chat.respond_with(lambda do |current_context|
          Captain::Runtime::PartRegistry.new(current_context).accept!(
            mode: 'council', parts: [{ fragment: 'Запись', executor_agent_id: 91 }, { fragment: 'Цена', executor_agent_id: 92 }]
          )
          reply('Text that the council replaces.')
        end)
        expect_initial_ask

        run_with

        expect(Captain::Runtime::Council).to have_received(:new).with(hash_including(staff_request: nil))
      end

      it 'leaves the human handoff of a run without a plan in the run state, for the response to carry out' do
        chat.respond_with(lambda do |current_context|
          current_context[:pending_human_handoff] = { reason: 'Only staff can do it' }
          current_context[:captain_v2_handoff_tool_called] = true
          RubyLLM::Tool::Halt.new('conversation_handoff')
        end)
        expect_initial_ask

        result = run_with

        expect(result.context).to include(pending_human_handoff: { reason: 'Only staff can do it' }, captain_v2_handoff_tool_called: true)
      end

      it 'transfers although an open part of the conversation waits for the customer' do
        context[:parts] = [{ 'id' => 'old-part', 'state' => 'waiting_customer', 'fragment' => 'Book a visit', 'proposed_operation' => nil }]
        chat.respond_with(transfer_to_colleague)
        colleague_chat.respond_with(reply('Выберите удобное время.'))
        expect_initial_ask

        result = run_with

        expect(result.output).to eq('Выберите удобное время.')
        expect(result.context[:current_agent]).to eq(colleague.name)
        expect(reminders(colleague_chat)).to be_empty
      end
    end

    describe 'a lone agent' do
      before { context[:agent_graph] = [{ id: 92, name: 'Scheduling' }] }

      it 'is not asked for a plan it cannot make, even when an old part still waits for the answer of the customer' do
        question = 'На какое время вас записать?'
        context[:parts] = [{ 'id' => 'old-part', 'state' => 'waiting_customer', 'fragment' => 'Book the synthetic scan', 'executor_agent_id' => 91,
                             'delivered' => [{ 'message_id' => 7, 'content' => question }] }]
        context[:conversation_history] = [{ role: 'assistant', content: question }]
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
