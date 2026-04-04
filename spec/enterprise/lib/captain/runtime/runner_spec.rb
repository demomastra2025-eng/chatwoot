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
      expect(params[:content]).to be_a(RubyLLM::Content)
      expect(params[:content].text).to eq('Lookup finished')
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
    let(:first_chat) { RuntimeRunnerSpecChat.new(ask_response: RubyLLM::Tool::Halt.new('handoff')) }
    let(:second_chat) { RuntimeRunnerSpecChat.new(complete_response: RubyLLM::Message.new(role: :assistant, content: 'Done')) }

    it 'builds a fresh chat for each handoff and reapplies the next agent configuration', :aggregate_failures do
      expect(Llm::ChatClient).to receive(:build).with(
        context: llm_context,
        model: 'gpt-4.1-mini',
        temperature: 0.2,
        params: { max_tokens: 111 },
        headers: { :'X-Agent' => 'primary' }
      ).and_return(first_chat).ordered

      expect(Llm::ChatClient).to receive(:build).with(
        context: llm_context,
        model: 'gpt-4.1-nano',
        temperature: 0.9,
        params: { max_tokens: 22 },
        headers: { :'X-Agent' => 'scenario' }
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
        llm_context: llm_context
      )

      expect(result.output).to eq('Done')
      expect(result.context[:current_agent]).to eq('scenario_agent')
      expect(first_chat.instructions).to eq('Primary instructions')
      expect(first_chat.schema).to eq(Captain::ResponseSchema)
      expect(second_chat.instructions).to eq('Scenario instructions')
      expect(second_chat.schema).to be_nil
    end
  end
end
