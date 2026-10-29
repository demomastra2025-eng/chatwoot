# frozen_string_literal: true

require 'rails_helper'

class RuntimeRunnerSpecChat
  attr_reader :messages, :temperature, :params, :headers, :instructions, :tools, :schema

  def initialize(ask_response: nil, complete_response: nil)
    @ask_response = ask_response
    @complete_response = complete_response
    @messages = []
  end

  def with_temperature(value)
    @temperature = value
    self
  end

  def with_params(**value)
    @params = value
    self
  end

  def with_headers(**value)
    @headers = value
    self
  end

  def with_instructions(value)
    @instructions = value
    self
  end

  def with_tools(*value, replace: false, concurrency: nil)
    @tools = { value: value, replace: replace }
    @tool_concurrency = concurrency
    self
  end

  def with_schema(value)
    @schema = value
    self
  end

  def add_message(message_or_attributes)
    message = message_or_attributes.is_a?(RubyLLM::Message) ? message_or_attributes : RubyLLM::Message.new(message_or_attributes)
    @messages << message
    message
  end

  def ask(_input)
    @ask_response
  end

  def complete
    @complete_response
  end
end

RuntimeRunnerSpecTool = Struct.new(:name, :description) do
  def parameters = {}
end

# Plays a model that makes the given tool calls one at a time, each in a step of its own, through the tools the runtime bound to the
# chat, and then answers. A halted call ends the step, as in RubyLLM.
RuntimeRunnerSpecScriptedChat = Class.new(RuntimeRunnerSpecChat) do
  def initialize(calls, final_response)
    super()
    @calls = calls.dup
    @final_response = final_response
  end

  def ask(input)
    add_message(role: :user, content: input)
    complete
  end

  def complete
    tools = Array(@tools&.dig(:value)).index_by { |tool| tool.name.to_s }
    until @calls.empty?
      name, arguments = @calls.shift
      id = "call_#{messages.size}"
      add_message(role: :assistant, content: '', tool_calls: { id => RubyLLM::ToolCall.new(id: id, name: name, arguments: arguments) })
      result = tools.fetch(name).call(arguments)
      add_message(role: :tool, content: result.is_a?(RubyLLM::Tool::Halt) ? result.content : result.to_s, tool_call_id: id)
      return result if result.is_a?(RubyLLM::Tool::Halt)
    end
    add_message(role: :assistant, content: @final_response)
  end
end

# A tool of a clinic agent as the guards of a run see it: a read, or an action that a reply suggestion only proposes to the operator.
RuntimeRunnerSpecClinicTool = Class.new(Captain::Runtime::Tool) do
  params(type: 'object', properties: {}, required: [], additionalProperties: true)

  attr_reader :calls

  def initialize(tool_name, action: false)
    super()
    @tool_name = tool_name
    @action = action
    @calls = 0
  end

  def name = @tool_name
  def description = "Spec #{@tool_name}"
  def metadata = @action ? { risk_level: 'high', idempotent: false } : { read_only: true, risk_level: 'low' }

  def perform(_tool_context, **arguments)
    @calls += 1
    "#{@tool_name}: #{arguments.to_json}"
  end
end

RSpec.describe Captain::Runtime::Runner do
  subject(:runner) { described_class.new }

  describe '#build_message_params' do
    it 'restores assistant tool calls as RubyLLM::ToolCall objects' do
      params = Captain::Runtime::HistoryRestorer.build_message_params(
        {
          role: :assistant,
          content: '',
          tool_calls: [
            { id: 'call_1', name: 'lookup_contact', arguments: { contact_id: 123 } }
          ]
        }
      )

      expect(params[:role]).to eq(:assistant)
      expect(params[:tool_calls].keys).to eq(['call_1'])
      expect(params[:tool_calls]['call_1']).to be_a(RubyLLM::ToolCall)
      expect(params[:tool_calls]['call_1'].name).to eq('lookup_contact')
      expect(params[:tool_calls]['call_1'].arguments).to eq(contact_id: 123)
    end

    it 'accepts persisted history with string keys' do
      params = Captain::Runtime::HistoryRestorer.build_message_params(
        {
          'role' => 'tool',
          'content' => 'Lookup finished',
          'tool_call_id' => 'call_1'
        }
      )

      expect(params[:role]).to eq(:tool)
      expect(params[:tool_call_id]).to eq('call_1')
      expect(params[:content]).to eq('Lookup finished')
    end
  end

  describe '#build_content' do
    it 'restores multimodal arrays as RubyLLM::Content with attachments' do
      content = Captain::Runtime::HistoryRestorer.build_content(
        [
          { type: 'text', text: 'Please inspect this screenshot' },
          { type: 'image_url', image_url: { url: 'https://example.com/error.png' } }
        ]
      )

      expect(content).to be_a(RubyLLM::Content)
      expect(content.text).to eq('Please inspect this screenshot')
      expect(content.attachments.first.source.to_s).to eq('https://example.com/error.png')
    end
  end

  describe '#last_message_matches?' do
    it 'matches equivalent multimodal RubyLLM::Content payloads' do
      existing_message = RubyLLM::Message.new(
        role: :user,
        content: RubyLLM::Content.new('Same text', ['https://example.com/image.png'])
      )
      chat = instance_double(RubyLLM::Chat, messages: [existing_message])
      input = RubyLLM::Content.new('Same text', ['https://example.com/image.png'])

      expect(Captain::Runtime::InputComparer.last_message_matches?(chat, input)).to be(true)
    end
  end

  describe '#run' do
    let(:llm_context) { instance_double(RubyLLM::Context) }
    let(:account) { instance_double(Account, id: 42) }
    let(:first_agent) do
      Captain::Runtime::Agent.new(
        name: 'assistant_agent',
        instructions: 'Primary instructions',
        model: 'gpt-4.1-mini',
        temperature: 0.2,
        response_schema: Captain::ResponseSchema,
        headers: { 'X-Agent' => 'primary' },
        params: { max_tokens: 111 }
      )
    end
    let(:second_agent) do
      Captain::Runtime::Agent.new(
        name: 'scenario_agent',
        instructions: 'Scenario instructions',
        model: 'gpt-4.1-nano',
        temperature: 0.9,
        response_schema: nil,
        headers: { 'X-Agent' => 'scenario' },
        params: { max_tokens: 22 }
      )
    end

    it 'runs the one agent it is given, with the chat configuration of that agent', :aggregate_failures do
      allow(Llm::Models).to receive(:model_config).and_call_original
      model_config = Llm::Models.model_config(second_agent.model, account: account).merge('supported_parameters' => %w[temperature max_tokens])
      allow(Llm::Models).to receive(:model_config).with(second_agent.model, account: account).and_return(model_config)
      chat = RuntimeRunnerSpecChat.new(ask_response: RubyLLM::Message.new(role: :assistant, content: 'Done'))
      expect(Llm::Runtime).to receive(:build_chat).once.with(
        feature: :captain_agent, account: account, model: 'gpt-4.1-nano', runtime_preferences: {},
        options: { context: llm_context, temperature: 0.9, params: { max_tokens: 22 }, headers: { :'X-Agent' => 'scenario' } }
      ).and_return(chat)

      result = runner.run(second_agent, 'Help me', registry: { first_agent.name => first_agent, second_agent.name => second_agent },
                                                   llm_context: llm_context, account: account)

      expect(result.output).to eq('Done')
      expect(result.context[:current_agent]).to eq('scenario_agent')
      expect(chat.instructions).to eq('Scenario instructions')
      expect(chat.schema).to be_nil
    end

    it 'never moves the run to another agent, whatever the context or a tool halt says' do
      chat = RuntimeRunnerSpecChat.new(ask_response: RubyLLM::Tool::Halt.new('Transferred to scenario'))
      expect(Llm::Runtime).to receive(:build_chat).once.and_return(chat)

      result = runner.run(first_agent, 'Help me', context: { pending_handoff: { target_agent: second_agent } },
                                                  registry: { first_agent.name => first_agent, second_agent.name => second_agent },
                                                  llm_context: llm_context, account: account)

      expect(result.error).to be_nil
      expect(result.output).to eq('Transferred to scenario')
      expect(result.context[:current_agent]).to eq('assistant_agent')
    end

    it 'normalizes structured output when the runtime continues with complete' do
      agent = Captain::Runtime::Agent.new(
        name: 'assistant_agent',
        instructions: 'Primary instructions',
        model: 'gpt-4.1-mini',
        temperature: 0.2,
        response_schema: Captain::ConversationCompletionSchema
      )
      response = instance_double(
        RubyLLM::Message,
        content: { complete: true, reason: 'done', message: '' },
        tool_call?: false,
        input_tokens: nil,
        output_tokens: nil
      )
      chat = RuntimeRunnerSpecChat.new(complete_response: response)

      allow(Captain::Runtime::InputComparer).to receive(:last_message_matches?).and_return(true)
      expect(Llm::Runtime).to receive(:build_chat).and_return(chat)
      expect(Llm::StructuredOutputPolicy).to receive(:execute).with(chat: chat).and_call_original

      result = runner.run(agent, 'Continue', registry: { agent.name => agent }, llm_context: llm_context, account: account)

      expect(result.output).to eq(response.content)
    end

    it 'observes restored input without asking again or duplicating the user history' do
      agent = Captain::Runtime::Agent.new(name: 'assistant_10', model: 'gpt-4.1-mini')
      response = RubyLLM::Message.new(role: :assistant, content: 'Done', input_tokens: 3, output_tokens: 2)
      chat = RuntimeRunnerSpecChat.new(complete_response: response)
      history = [{ role: :user, content: 'Already supplied' }]
      expect(Llm::Runtime).to receive(:build_chat).and_return(chat)
      expect(Llm::Runtime).not_to receive(:ask)
      expect(chat).not_to receive(:ask)
      expect(Llm::Runtime).to receive(:complete).with(
        chat,
        account: account,
        model: 'gpt-4.1-mini',
        observability: hash_including(assistant_id: 10, current_agent: 'assistant_10', conversation_record_id: 25)
      ).once.and_call_original

      result = runner.run(
        agent,
        'Already supplied',
        context: { conversation_history: history, state: { assistant_id: 10, conversation: { id: 25 } } },
        registry: { agent.name => agent },
        llm_context: llm_context,
        account: account
      )

      expect(result.output).to eq('Done')
      expect(chat.messages.select { |message| message.role == :user }.map(&:content)).to eq(['Already supplied'])
    end

    it 'attributes the events of the run to the agent it runs, as its context preparer sets it' do
      events = []
      subscriber = ActiveSupport::Notifications.subscribe('llm.chat.complete') do |*args|
        events << ActiveSupport::Notifications::Event.new(*args)
      end
      agent = Captain::Runtime::Agent.new(name: 'assistant_11', model: 'gpt-4.1-nano')
      agent.context_preparer = ->(wrapper) { wrapper.context[:state][:assistant_id] = 11 }
      chat = RuntimeRunnerSpecChat.new(ask_response: RubyLLM::Message.new(role: :assistant, content: 'Done'))
      expect(Llm::Runtime).to receive(:build_chat).once.and_return(chat)

      result = Llm::EventBus.with_context(assistant_id: 10, conversation_id: 999) do
        runner.run(agent, 'Help me', context: { state: { assistant_id: 10, conversation: { id: 25, display_id: 7 },
                                                         private_tool_results: 'Synthetic private context' } },
                                     registry: { agent.name => agent }, llm_context: llm_context, account: account)
      end

      expect(result.output).to eq('Done')
      expect(events.map(&:payload)).to contain_exactly(
        hash_including('assistant_id' => 11, 'current_agent' => 'assistant_11', 'model' => 'gpt-4.1-nano', 'account_id' => account.id,
                       'conversation_id' => 25, 'conversation_display_id' => 7)
      )
      expect(events.map(&:payload).to_json).not_to include('Synthetic private context')
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
    end

    it 'finalizes generic halt responses that are not agent-to-agent handoffs' do
      agent = Captain::Runtime::Agent.new(name: 'assistant_agent')
      chat = RuntimeRunnerSpecChat.new(ask_response: RubyLLM::Tool::Halt.new('conversation_handoff'))

      expect(Llm::Runtime).to receive(:build_chat).and_return(chat)

      result = runner.run(agent, 'Escalate', registry: { agent.name => agent }, llm_context: llm_context, account: account)

      expect(result.output).to eq('conversation_handoff')
      expect(result.context[:current_agent]).to eq('assistant_agent')
    end

    it 'returns a typed runtime error when a tool loop is stopped' do
      agent = Captain::Runtime::Agent.new(name: 'assistant_agent')
      terminal_result = Captain::ToolResult.failure(
        error: 'Tool request limit reached',
        retryable: false,
        audit: { failure_reason: 'tool_request_limit' }
      )
      chat = RuntimeRunnerSpecChat.new(ask_response: RubyLLM::Tool::Halt.new(Captain::ToolResult.render(terminal_result)))

      expect(Llm::Runtime).to receive(:build_chat).and_return(chat)

      result = runner.run(
        agent,
        'Keep searching',
        context: {
          Captain::Runtime::ToolWrapper::TERMINAL_TOOL_STOP_KEY => {
            tool_name: 'search_deals',
            result: terminal_result
          }
        },
        registry: { agent.name => agent },
        llm_context: llm_context,
        account: account
      )

      expect(result.output).to be_nil
      expect(result.error).to be_a(described_class::ToolLoopStopped)
      expect(result.error.message).to eq('Tool request limit reached')
      expect(result.context[Captain::Runtime::ToolWrapper::TERMINAL_TOOL_STOP_KEY]).to be_present
    end

    # A live conversation that loops is handed to staff; a reply suggestion is a draft for the operator, so it ends with the error
    # and the runner of the conversation writes the draft from the results so far (AgentRunnerService#finalization_only_retry_response).
    describe 'a loop in the run of a conversation' do
      let(:agent) { Captain::Runtime::Agent.new(name: 'assistant_agent') }
      let(:agent_session) { Captain::Conversation::AgentSession.new }
      let(:terminal_result) do
        Captain::ToolResult.failure(error: 'Tool request limit reached', retryable: false, audit: { failure_reason: 'tool_request_limit' })
      end
      let(:tool_call) do
        RubyLLM::Message.new(role: :assistant, content: '',
                             tool_calls: { 'call_1' => RubyLLM::ToolCall.new(id: 'call_1', name: 'search_available_slots', arguments: {}) })
      end

      def run_conversation(source, response:, **)
        allow(Llm::Runtime).to receive(:build_chat).and_return(RuntimeRunnerSpecChat.new(ask_response: response, complete_response: response))
        context = { state: { source: source }, agent_session: agent_session }
        context[Captain::Runtime::ToolWrapper::TERMINAL_TOOL_STOP_KEY] = { tool_name: 'search_available_slots', result: terminal_result }
        runner.run(agent, 'Keep searching', context: context, registry: { agent.name => agent }, llm_context: llm_context, account: account, **)
      end

      it 'is a technical failure of a live conversation: staff take it over' do
        result = run_conversation('incoming_message', response: RubyLLM::Tool::Halt.new(Captain::ToolResult.render(terminal_result)))

        expect(result.error).to be_a(described_class::TechnicalFailure)
        expect(result.context[:technical_failure]).to include('reason' => 'tool_loop')
      end

      it 'ends a reply suggestion with the loop error and no technical failure, so its draft is still written' do
        result = run_conversation('reply_suggestion', response: RubyLLM::Tool::Halt.new(Captain::ToolResult.render(terminal_result)))

        expect(result.error).to be_a(described_class::ToolLoopStopped)
        expect(result.context).not_to have_key(:technical_failure)
      end

      it 'treats the turn limit the same way' do
        live = run_conversation('incoming_message', response: tool_call, max_turns: 1)
        suggestion = run_conversation('reply_suggestion', response: tool_call, max_turns: 1)

        expect(live.context[:technical_failure]).to include('reason' => 'max_turns')
        expect(suggestion.error).to be_a(described_class::MaxTurnsExceeded)
        expect(suggestion.context).not_to have_key(:technical_failure)
      end
    end

    # PROD 26.10 (c94098caa): reply suggestions failed with tool_loop and the operators saw «ИИ не смог подготовить ответ». In a
    # suggestion an action only prepares an approval card, but the second call of an action was refused as a retry and the fourth
    # identical slot search hit the attempt limit; either ended the run as a technical failure, which dropped the prepared cards.
    describe 'the reply suggestion that ended as tool_loop' do
      let(:agent_session) { Captain::Conversation::AgentSession.new }
      let(:read_tools) do
        %w[faq_lookup search_appointments search_available_slots search_scheduling_resources get_contact].index_with do |name|
          RuntimeRunnerSpecClinicTool.new(name)
        end
      end
      let(:action_tools) { %w[cancel_appointment create_task].index_with { |name| RuntimeRunnerSpecClinicTool.new(name, action: true) } }
      let(:agent) do
        Captain::Runtime::Agent.new(name: 'assistant_agent', instructions: 'Clinic instructions', tools: read_tools.values + action_tools.values)
      end
      # 17 calls: create_task twice, cancel_appointment twice for the same appointment, and the same slot search four times.
      let(:calls) do
        slots = { service_id: 7, date: '2026-10-27' }
        [
          ['faq_lookup', { query: 'отмена записи' }],
          ['search_appointments', {}],
          ['cancel_appointment', { appointment_id: 501, reason: 'Пациентка просит отменить' }],
          ['search_available_slots', slots],
          ['create_task', { title: 'Перезвонить Әлие' }],
          ['search_available_slots', slots],
          ['create_task', { title: 'Перезвонить Әлие завтра утром' }],
          ['search_scheduling_resources', { query: 'терапевт' }],
          ['search_available_slots', slots],
          ['cancel_appointment', { appointment_id: 501, reason: 'Пациентка заболела' }],
          ['get_contact', {}],
          ['search_available_slots', slots],
          ['search_available_slots', { service_id: 7, date: '2026-10-28' }],
          ['search_appointments', { status: 'scheduled' }],
          ['faq_lookup', { query: 'перенос записи' }],
          ['search_scheduling_resources', { query: 'педиатр' }],
          ['get_contact', { include: 'appointments' }]
        ]
      end
      let(:draft) { 'Отмену записи и звонок администратора передала на подтверждение.' }

      before do
        allow(Llm::Models).to receive(:supports?).and_return(true)
        # A card per call; the cards a call replaces (a corrected cancellation of the same appointment) leave the run's list.
        prepared = 0
        allow(Captain::ReplySuggestion::ActionApprovalService).to receive(:intercept) do |tool:, tool_context:, arguments:, replaces: []|
          cards = (tool_context.context[cards_key] ||= [])
          cards.reject! { |item| replaces.include?(item['action_id']) }
          prepared += 1
          card = { 'action_id' => "card-#{prepared}", 'tool_name' => tool.name, 'status' => 'pending', 'title' => tool.name,
                   'description' => arguments.values.join(', ') }
          cards << card
          JSON.generate(success: true, status: 'pending_operator_approval', action_id: card['action_id'], action: tool.name)
        end
      end

      def cards_key = Captain::ReplySuggestion::ActionApprovalService::CONTEXT_KEY

      def suggest(calls)
        chat = RuntimeRunnerSpecScriptedChat.new(calls, draft)
        allow(Llm::Runtime).to receive(:build_chat).and_return(chat)
        context = { state: { source: 'reply_suggestion' }, agent_session: agent_session }
        result = runner.run(agent, 'Отмените мою запись, пожалуйста', context: context, registry: { agent.name => agent },
                                                                      llm_context: llm_context, account: account)
        [result, chat.messages.select { |message| message.role == :tool }.map(&:content)]
      end

      it 'answers all 17 calls and ends with the draft, without a technical failure' do
        result, tool_results = suggest(calls)

        expect(result.error).to be_nil
        expect(result.output).to eq(draft)
        expect(result.context.keys).not_to include(:technical_failure, Captain::Runtime::ToolWrapper::TERMINAL_TOOL_STOP_KEY)
        expect(result.context.dig(Captain::Runtime::ToolLoopGuard::REQUEST_COUNTS_KEY, :total)).to eq(16)
        expect(tool_results.size).to eq(17)
      end

      # The release branch keeps one card per appointment and up to three cards of another action in a run (see
      # ToolWrapper#suggestion_card_repeat_result): the corrected cancellation replaces its card, the second task is a card of its own.
      it 'keeps the approval cards: a corrected cancellation replaces its card and another task gets a card of its own' do
        result, tool_results = suggest(calls)

        expect(result.context[cards_key]).to match(
          [include('action_id' => 'card-2', 'tool_name' => 'create_task'), include('action_id' => 'card-3', 'tool_name' => 'create_task'),
           include('action_id' => 'card-4', 'tool_name' => 'cancel_appointment', 'description' => '501, Пациентка заболела')]
        )
        expect(Captain::ReplySuggestion::ActionApprovalService).to have_received(:intercept)
          .with(hash_including(replaces: ['card-1']))
        expect(Captain::ReplySuggestion::ActionApprovalService).to have_received(:intercept).exactly(4).times
        expect(action_tools.values.sum(&:calls)).to eq(0)
        expect(tool_results.values_at(6, 9)).to all(include('pending_operator_approval'))
      end

      it 'answers the repeated slot search from the first result' do
        _, tool_results = suggest(calls)

        expect(read_tools['search_available_slots'].calls).to eq(2)
        expect(tool_results.values_at(5, 8, 11)).to all(end_with(Captain::Runtime::ToolWrapper::REPEATED_READ_NOTE))
      end

      it 'ends a suggestion that keeps calling with the loop error, not a technical failure, and keeps the cards' do
        result, = suggest(calls + [['search_available_slots', { service_id: 7, date: '2026-10-29' }]])

        expect(result.error).to be_a(described_class::ToolLoopStopped)
        expect(result.context).not_to have_key(:technical_failure)
        expect(result.context[cards_key].pluck('action_id')).to eq(%w[card-2 card-3 card-4])
      end
    end

    it 'propagates a stale Captain response fence instead of converting it to a provider error' do
      stale_error = Captain::Conversation::ControlGenerationStaleError.new('Captain response run is stale')
      agent = Captain::Runtime::Agent.new(name: 'assistant_agent')
      chat = RuntimeRunnerSpecChat.new
      allow(chat).to receive(:ask).and_raise(stale_error)
      expect(Llm::Runtime).to receive(:build_chat).and_return(chat)

      expect do
        runner.run(agent, 'Respond', registry: { agent.name => agent }, llm_context: llm_context, account: account)
      end.to raise_error(stale_error)
    end

    it 'continues from restored history without exposing tools during finalization-only retries' do
      tool = RuntimeRunnerSpecTool.new('create_deal', 'Create deal')
      agent = Captain::Runtime::Agent.new(
        name: 'assistant_agent',
        instructions: 'Primary instructions',
        tools: [tool]
      )
      history = [
        { role: :user, content: 'Create a deal' },
        {
          role: :assistant,
          content: '',
          agent_name: 'assistant_agent',
          tool_calls: [{ id: 'call_1', name: 'create_deal', arguments: { title: 'New deal' } }]
        },
        { role: :tool, content: '{"deal_id":123}', tool_call_id: 'call_1' }
      ]
      response = RubyLLM::Message.new(role: :assistant, content: 'Deal created')
      chat = RuntimeRunnerSpecChat.new(complete_response: response)

      allow(Llm::Models).to receive(:supports?).and_return(true)
      expect(Llm::Runtime).to receive(:build_chat).and_return(chat)
      expect(Llm::Runtime).not_to receive(:ask)
      expect(Llm::Runtime).to receive(:complete).once.and_call_original

      result = runner.run(
        agent,
        nil,
        context: { conversation_history: history },
        registry: { agent.name => agent },
        llm_context: llm_context,
        account: account,
        finalization_only: true,
        continue_from_history: true
      )

      expect(result.output).to eq('Deal created')
      expect(chat.instructions).to include('using only the completed tool result messages')
      expect(chat.tools).to be_nil
      expect(chat.messages.map(&:role)).to include(:tool)
      expect(chat.messages.count { |message| message.role == :user }).to eq(1)
      expect(result.context[:captain_v2_bound_tool_ids]).to eq([])
    end

    describe 'provider safety refusal cross-vendor fallback' do
      let(:fallback_events) { [] }
      let(:fallback_subscriber) do
        ActiveSupport::Notifications.subscribe('llm.run.provider_refusal_fallback') do |*args|
          fallback_events << ActiveSupport::Notifications::Event.new(*args)
        end
      end

      before do
        allow(Llm::Models).to receive(:supports?).and_return(true)
        fallback_subscriber
      end

      after do
        ActiveSupport::Notifications.unsubscribe(fallback_subscriber)
      end

      it 'switches once from a refusing OpenAI model to google/gemini-3.8-flash on turn 1' do
        agent = Captain::Runtime::Agent.new(
          name: 'urology_agent',
          model: 'openai/gpt-6-luna',
          response_schema: Captain::ResponseSchema
        )
        primary_chat = RuntimeRunnerSpecChat.new(
          ask_response: RubyLLM::Message.new(role: :assistant, content: "I'm sorry, but I cannot assist with that request.")
        )
        fallback_payload = {
          'patient_language' => 'ru',
          'response' => 'Приём уролога стоит 8000 тенге.',
          'response_mode' => 'reply',
          'reasoning' => 'Ответил по прайсу клиники.',
          'artifact_ids' => []
        }
        fallback_chat = RuntimeRunnerSpecChat.new(
          ask_response: RubyLLM::Message.new(role: :assistant, content: fallback_payload.to_json)
        )
        built_models = []
        completed_models = []

        allow(Llm::Runtime).to receive(:build_chat) do |**kwargs|
          built_models << kwargs[:model]
          built_models.size == 1 ? primary_chat : fallback_chat
        end
        allow(Llm::Runtime).to receive(:ask) do |chat, input, **|
          Llm::StructuredOutputPolicy.execute(chat: chat) { chat.ask(input) }
        end

        result = runner.run(
          agent,
          'Сколько стоит приём уролога при боли в паху?',
          registry: { agent.name => agent },
          llm_context: llm_context,
          account: account,
          callbacks: { llm_call_complete: [->(_name, model, *_rest) { completed_models << model }] }
        )

        expect(result.error).to be_nil
        expect(result.output).to include('response' => 'Приём уролога стоит 8000 тенге.')
        expect(built_models).to eq(['openai/gpt-6-luna', 'google/gemini-3.8-flash'])
        expect(completed_models).to eq(['google/gemini-3.8-flash'])
        expect(fallback_events.size).to eq(1)
        expect(fallback_events.first.payload).to include(
          'from_model' => 'openai/gpt-6-luna',
          'to_model' => 'google/gemini-3.8-flash',
          'turn' => 1
        )
      end

      it 'preserves completed tool results without re-executing tools when a refusal happens after a tool call' do
        read_tool = RuntimeRunnerSpecClinicTool.new('search_available_slots')
        agent = Captain::Runtime::Agent.new(
          name: 'urology_agent',
          model: 'openai/gpt-6-luna',
          tools: [read_tool],
          response_schema: Captain::ResponseSchema
        )
        primary_chat = RuntimeRunnerSpecScriptedChat.new(
          [['search_available_slots', { service_id: 42 }]],
          "I'm sorry, but I cannot assist with that request."
        )
        fallback_payload = {
          'patient_language' => 'ru',
          'response' => 'Свободное окно у уролога есть на 10:00.',
          'response_mode' => 'reply',
          'reasoning' => 'Использовал уже полученное расписание.',
          'artifact_ids' => []
        }
        fallback_chat = RuntimeRunnerSpecChat.new(
          complete_response: RubyLLM::Message.new(role: :assistant, content: fallback_payload.to_json)
        )
        chats = [primary_chat, fallback_chat]

        allow(Llm::Runtime).to receive(:build_chat) { chats.shift }
        allow(Llm::Runtime).to receive(:ask) do |chat, input, **|
          Llm::StructuredOutputPolicy.execute(chat: chat) { chat.ask(input) }
        end
        allow(Llm::Runtime).to receive(:complete) do |chat, **|
          Llm::StructuredOutputPolicy.execute(chat: chat) { chat.complete }
        end

        result = runner.run(
          agent,
          'Запишите к урологу на утро',
          registry: { agent.name => agent },
          llm_context: llm_context,
          account: account
        )

        expect(result.error).to be_nil
        expect(result.output).to include('response' => 'Свободное окно у уролога есть на 10:00.')
        expect(read_tool.calls).to eq(1)
        expect(fallback_chat.messages.map(&:role)).to include(:user, :assistant, :tool)
      end

      it 'stops after one cross-vendor fallback attempt and returns ProviderRefusalError on double refusal' do
        agent = Captain::Runtime::Agent.new(
          name: 'urology_agent',
          model: 'google/gemini-3.8-flash',
          response_schema: Captain::ResponseSchema
        )
        primary_chat = RuntimeRunnerSpecChat.new(
          ask_response: RubyLLM::Message.new(role: :assistant, content: "I'm sorry, but I cannot assist with that request.")
        )
        fallback_chat = RuntimeRunnerSpecChat.new(
          ask_response: RubyLLM::Message.new(role: :assistant, content: 'I apologize, but I cannot fulfill this request.')
        )
        built_models = []

        allow(Llm::Runtime).to receive(:build_chat) do |**kwargs|
          built_models << kwargs[:model]
          built_models.size == 1 ? primary_chat : fallback_chat
        end
        allow(Llm::Runtime).to receive(:ask) do |chat, input, **|
          Llm::StructuredOutputPolicy.execute(chat: chat) { chat.ask(input) }
        end

        result = runner.run(
          agent,
          'Вопрос врачу',
          registry: { agent.name => agent },
          llm_context: llm_context,
          account: account
        )

        expect(result.output).to be_nil
        expect(result.error).to be_a(Llm::StructuredOutputPolicy::ProviderRefusalError)
        expect(built_models).to eq(['google/gemini-3.8-flash', 'anthropic/claude-haiku-5.5'])
        expect(fallback_events.size).to eq(1)
      end

      it 'recognizes unprefixed legacy model ids (e.g. gemini-3.1-pro-preview) and switches to a different vendor' do
        expect(Captain::Runtime::ProviderRefusalFallback.vendor_for('gemini-3.1-pro-preview')).to eq('google')
        expect(Captain::Runtime::ProviderRefusalFallback.vendor_for('claude-sonnet-4-6')).to eq('anthropic')
        expect(Captain::Runtime::ProviderRefusalFallback.vendor_for('gpt-5.4')).to eq('openai')
      end
    end
  end
end
