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

  def with_tools(*value, replace: false)
    @tools = { value: value, replace: replace }
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
    let(:handoff_response) { RubyLLM::Tool::Halt.new('Transferred to scenario') }
    let(:first_chat) { RuntimeRunnerSpecChat.new(ask_response: handoff_response) }
    let(:second_chat) { RuntimeRunnerSpecChat.new(complete_response: RubyLLM::Message.new(role: :assistant, content: 'Done')) }

    it 'builds a fresh chat for each handoff and reapplies the next agent configuration', :aggregate_failures do
      allow(runner).to receive(:handoff_requested?).and_call_original
      allow(runner).to receive(:handoff_requested?).with(anything, handoff_response).and_return(true)

      expect(Llm::Runtime).to receive(:build_chat).with(
        feature: :captain_agent,
        account: account,
        model: 'gpt-4.1-mini',
        options: {
          context: llm_context,
          temperature: 0.2,
          params: { max_tokens: 111 },
          headers: { :'X-Agent' => 'primary' },
          thinking: nil
        }
      ).and_return(first_chat).ordered

      expect(Llm::Runtime).to receive(:build_chat).with(
        feature: :captain_agent,
        account: account,
        model: 'gpt-4.1-nano',
        options: {
          context: llm_context,
          temperature: 0.9,
          params: { max_tokens: 22 },
          headers: { :'X-Agent' => 'scenario' },
          thinking: nil
        }
      ).and_return(second_chat).ordered

      result = runner.run(
        first_agent,
        'Help me',
        context: {
          pending_handoff: { target_agent: second_agent }
        },
        registry: {
          first_agent.name => first_agent,
          second_agent.name => second_agent
        },
        llm_context: llm_context,
        account: account
      )

      expect(result.output).to eq('Done')
      expect(result.context[:current_agent]).to eq('scenario_agent')
      expect(first_chat.instructions).to eq('Primary instructions')
      expect(first_chat.schema).to eq(Captain::ResponseSchema)
      expect(second_chat.instructions).to eq('Scenario instructions')
      expect(second_chat.schema).to be_nil
    end

    it 'blocks self-handoff instead of rebuilding the same agent again' do
      agent = Captain::Runtime::Agent.new(name: 'assistant_agent')
      self_handoff_response = RubyLLM::Tool::Halt.new('Transferred to assistant')
      chat = RuntimeRunnerSpecChat.new(ask_response: self_handoff_response)

      expect(Llm::Runtime).to receive(:build_chat).once.and_return(chat)

      result = runner.run(
        agent,
        'handoff to yourself',
        context: { pending_handoff: { target_agent: agent } },
        registry: { agent.name => agent },
        llm_context: llm_context,
        account: account
      )

      expect(result.output).to be_nil
      expect(result.error).to be_a(described_class::SelfHandoffError)
      expect(result.error.message).to eq('Agent assistant_agent attempted to hand off to itself')
      expect(result.context[:current_agent]).to eq('assistant_agent')
    end

    it 'resolves string handoff targets through the runtime registry' do
      handoff_response = RubyLLM::Tool::Halt.new('Transferred to scenario')
      first_chat = RuntimeRunnerSpecChat.new(ask_response: handoff_response)
      second_chat = RuntimeRunnerSpecChat.new(complete_response: RubyLLM::Message.new(role: :assistant, content: 'Done'))

      allow(runner).to receive(:handoff_requested?).and_call_original
      allow(runner).to receive(:handoff_requested?).with(anything, handoff_response).and_return(true)
      expect(Llm::Runtime).to receive(:build_chat).and_return(first_chat, second_chat)

      result = runner.run(
        first_agent,
        'Help me',
        context: { pending_handoff: { target_agent: 'scenario_agent' } },
        registry: { first_agent.name => first_agent, second_agent.name => second_agent },
        llm_context: llm_context,
        account: account
      )

      expect(result.output).to eq('Done')
      expect(result.context[:current_agent]).to eq('scenario_agent')
    end

    it 'returns a safe runtime error for stale handoff target identifiers' do
      handoff_response = RubyLLM::Tool::Halt.new('Transferred to deleted scenario')
      chat = RuntimeRunnerSpecChat.new(ask_response: handoff_response)

      allow(runner).to receive(:handoff_requested?).and_call_original
      allow(runner).to receive(:handoff_requested?).with(anything, handoff_response).and_return(true)
      expect(Llm::Runtime).to receive(:build_chat).once.and_return(chat)

      result = runner.run(
        first_agent,
        'Help me',
        context: { pending_handoff: { target_agent: 'deleted_scenario_agent' } },
        registry: { first_agent.name => first_agent },
        llm_context: llm_context,
        account: account
      )

      expect(result.output).to be_nil
      expect(result.error).to be_a(described_class::AgentNotFoundError)
      expect(result.error.message).to eq("Handoff failed: Agent 'deleted_scenario_agent' not found in registry")
      expect(result.context[:current_agent]).to eq('assistant_agent')
      expect(result.context).not_to have_key(:pending_handoff)
    end

    it 'returns a safe runtime error for malformed handoff state without a target' do
      handoff_response = RubyLLM::Tool::Halt.new('Transferred to nowhere')
      chat = RuntimeRunnerSpecChat.new(ask_response: handoff_response)

      allow(runner).to receive(:handoff_requested?).and_call_original
      allow(runner).to receive(:handoff_requested?).with(anything, handoff_response).and_return(true)
      expect(Llm::Runtime).to receive(:build_chat).once.and_return(chat)

      result = runner.run(
        first_agent,
        'Help me',
        context: { pending_handoff: {} },
        registry: { first_agent.name => first_agent },
        llm_context: llm_context,
        account: account
      )

      expect(result.output).to be_nil
      expect(result.error).to be_a(described_class::AgentNotFoundError)
      expect(result.error.message).to eq('Handoff failed: target agent is missing')
      expect(result.context[:current_agent]).to eq('assistant_agent')
      expect(result.context).not_to have_key(:pending_handoff)
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
      expect(result.context[:captain_v2_bound_tool_ids]).to eq([])
    end
  end
end
