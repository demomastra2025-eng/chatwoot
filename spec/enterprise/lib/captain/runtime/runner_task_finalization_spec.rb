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
  # The message already has its accepted request plan: these examples cover task finalization only, and
  # a graph run without a plan would otherwise be asked to call plan_request before it may reply.
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

  it 'asks a graph run without a request plan to plan once before replying, then reports the request as unfinished' do
    context.delete(:part_plan_accepted)
    context[:agent_tasks] = []
    chat.respond_with(reply('Unplanned first draft'), reply('Unplanned second draft'))
    expect_initial_ask
    expect(Llm::Runtime).to receive(:complete).once.and_call_original

    result = run_with

    expect(result).to be_success
    expect(result.output).to eq(response: I18n.t('captain.coordination.unfinished', locale: :ru), reasoning: '')
    expect(chat.requests).to eq(%i[ask complete])
    expect(reminders.map(&:content)).to eq(['Call plan_request for this message before replying.'])
    expect(result.messages.none? { |message| message[:role] == :assistant }).to be(true)
  end

  it 'does not ask for a request plan during a finalization-only continuation that exposes no tools' do
    context.delete(:part_plan_accepted)
    context[:agent_tasks] = []
    context[:conversation_history] = [{ role: :user, content: input }]
    chat.respond_with(reply('The verified result is ready.'))
    expect(Llm::Runtime).not_to receive(:ask)
    expect(Llm::Runtime).to receive(:complete).once.and_call_original

    result = run_with(finalization_only: true, continue_from_history: true)

    expect(result).to be_success
    expect(result.output).to eq('The verified result is ready.')
    expect(chat.requests).to eq([:complete])
    expect(reminders).to be_empty
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
