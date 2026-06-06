# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Concerns::Agentable do
  let(:dummy_class) do
    Class.new do
      include Concerns::Agentable

      attr_accessor :temperature, :account

      def initialize(name: 'Test Agent', temperature: 0.8, account: nil)
        @name = name
        @temperature = temperature
        @account = account
      end

      def self.name
        'DummyClass'
      end

      private

      def agent_name
        @name
      end

      def prompt_context
        { base_key: 'base_value' }
      end
    end
  end

  let(:dummy_instance) { dummy_class.new }
  let(:mock_runtime_agent) { instance_double(Captain::Runtime::Agent) }

  before do
    allow(Captain::Runtime::Agent).to receive(:new).and_return(mock_runtime_agent)
    allow(Llm::Config).to receive(:model_for).and_return('gpt-4-turbo')
    allow(Captain::PromptRenderer).to receive(:render).and_return('rendered_template')
  end

  describe '#agent' do
    it 'creates a Captain::Runtime::Agent with correct parameters' do
      expect(Captain::Runtime::Agent).to receive(:new).with(
        name: 'Test Agent',
        instructions: instance_of(Proc),
        tools: [],
        model: 'gpt-4-turbo',
        temperature: 0.8,
        response_schema: Captain::ResponseSchema
      )

      dummy_instance.agent
    end

    it 'defaults missing temperature to 1.0' do
      dummy_instance.temperature = nil

      expect(Captain::Runtime::Agent).to receive(:new).with(
        hash_including(temperature: 1.0)
      )

      dummy_instance.agent
    end

    it 'preserves an explicit zero temperature' do
      dummy_instance.temperature = 0

      expect(Captain::Runtime::Agent).to receive(:new).with(
        hash_including(temperature: 0.0)
      )

      dummy_instance.agent
    end

    it 'converts temperature to float' do
      dummy_instance.temperature = '0.5'

      expect(Captain::Runtime::Agent).to receive(:new).with(
        hash_including(temperature: 0.5)
      )

      dummy_instance.agent
    end
  end

  describe '#agent_instructions' do
    it 'calls Captain::PromptRenderer with base context' do
      expect(Captain::PromptRenderer).to receive(:render).with(
        'dummy_class',
        hash_including(
          base_key: 'base_value',
          conversation: nil,
          contact: nil,
          communication_thread: nil,
          campaign: {},
          conversation_visible_fields: [],
          contact_visible_fields: []
        )
      )

      dummy_instance.agent_instructions
    end

    it 'merges context state when provided' do
      context_double = instance_double(Captain::Runtime::RunContext,
                                       context: {
                                         state: {
                                           conversation: { id: 123 },
                                           contact: { name: 'John' },
                                           communication_thread: { display_id: 9, current_channel_key: 'conversation:123' }
                                         }
                                       })

      expected_context = {
        base_key: 'base_value',
        conversation: { id: 123 },
        contact: { name: 'John' },
        communication_thread: { display_id: 9, current_channel_key: 'conversation:123' },
        campaign: {}
      }

      expect(Captain::PromptRenderer).to receive(:render).with(
        'dummy_class',
        hash_including(expected_context)
      )

      dummy_instance.agent_instructions(context_double)
    end

    it 'derives visible fields from raw state when prompt_context is absent' do
      context_double = instance_double(Captain::Runtime::RunContext,
                                       context: {
                                         state: {
                                           conversation: { id: 123, status: 'open' },
                                           contact: { name: 'John' },
                                           deal: { title: 'Enterprise renewal', stage_name: 'Negotiation' },
                                           task: { title: 'Follow up', status_name: 'In progress' },
                                           appointment: { status: 'confirmed' }
                                         }
                                       })

      expect(Captain::PromptRenderer).to receive(:render).with(
        'dummy_class',
        hash_including(
          conversation_visible_fields: %w[id status],
          contact_visible_fields: ['name'],
          deal_visible_fields: %w[title stage_name],
          task_visible_fields: %w[title status_name],
          appointment_visible_fields: ['status']
        )
      )

      dummy_instance.agent_instructions(context_double)
    end

    it 'merges campaign data from context state' do
      context_double = instance_double(Captain::Runtime::RunContext,
                                       context: {
                                         state: {
                                           conversation: { id: 123 },
                                           contact: { name: 'John' },
                                           campaign: { id: 10, title: 'Summer Sale', message: 'Check it out' }
                                         }
                                       })

      expect(Captain::PromptRenderer).to receive(:render).with(
        'dummy_class',
        hash_including(
          campaign: { id: 10, title: 'Summer Sale', message: 'Check it out' }
        )
      )

      dummy_instance.agent_instructions(context_double)
    end

    it 'prefers appointment data from prompt context when present' do
      context_double = instance_double(Captain::Runtime::RunContext,
                                       context: {
                                         state: {
                                           assistant_config: { 'context_access' => {} },
                                           deal: { id: 33, stage_name: 'Prospecting' },
                                           task: { id: 34, status_name: 'Open' },
                                           appointment: { id: 44, status: 'scheduled' },
                                           prompt_context: {
                                             deal: { 'stage_name' => 'Negotiation' },
                                             task: { 'status_name' => 'In progress' },
                                             appointment: { 'status' => 'confirmed' },
                                             communication_thread: {
                                               'display_id' => 77,
                                               'current_channel_key' => 'conversation:456'
                                             },
                                             visible_fields: {
                                               deal: ['stage_name'],
                                               task: ['status_name'],
                                               appointment: ['status']
                                             }
                                           }
                                         }
                                       })

      expect(Captain::PromptRenderer).to receive(:render).with(
        'dummy_class',
        hash_including(
          deal: { 'stage_name' => 'Negotiation' },
          task: { 'status_name' => 'In progress' },
          appointment: { 'status' => 'confirmed' },
          communication_thread: { 'display_id' => 77, 'current_channel_key' => 'conversation:456' },
          deal_visible_fields: ['stage_name'],
          task_visible_fields: ['status_name'],
          appointment_visible_fields: ['status']
        )
      )

      dummy_instance.agent_instructions(context_double)
    end

    it 'handles context without state' do
      context_double = instance_double(Captain::Runtime::RunContext, context: {})

      expect(Captain::PromptRenderer).to receive(:render).with(
        'dummy_class',
        hash_including(
          base_key: 'base_value'
        )
      )

      dummy_instance.agent_instructions(context_double)
    end
  end

  describe '#template_name' do
    it 'returns underscored class name' do
      expect(dummy_instance.send(:template_name)).to eq('dummy_class')
    end
  end

  describe '#agent_tools' do
    it 'returns empty array by default' do
      expect(dummy_instance.send(:agent_tools)).to eq([])
    end
  end

  describe '#agent_model' do
    it 'delegates model resolution through Llm::Config' do
      expect(dummy_instance.send(:agent_model)).to eq('gpt-4-turbo')
    end

    it 'uses gpt-5.4 as the agent fallback default' do
      expect(LlmConstants::DEFAULT_MODEL).to eq('gpt-5.4')
    end

    it 'passes the associated account when present' do
      account = create(:account, captain_models: { 'assistant' => 'gpt-5.2' })
      dummy_with_account = dummy_class.new(account: account)

      expect(Llm::Config).to receive(:model_for).with(
        feature: :assistant,
        account: account,
        fallback: LlmConstants::DEFAULT_MODEL
      ).and_return('gpt-5.2')

      expect(dummy_with_account.send(:agent_model)).to eq('gpt-5.2')
    end
  end

  describe '#agent_response_schema' do
    it 'returns Captain::ResponseSchema' do
      expect(dummy_instance.send(:agent_response_schema)).to eq(Captain::ResponseSchema)
    end
  end

  describe 'required methods' do
    let(:incomplete_class) do
      Class.new do
        include Concerns::Agentable
      end
    end

    let(:incomplete_instance) { incomplete_class.new }

    describe '#agent_name' do
      it 'raises NotImplementedError when not implemented' do
        expect { incomplete_instance.send(:agent_name) }
          .to raise_error(NotImplementedError, /must implement agent_name/)
      end
    end

    describe '#prompt_context' do
      it 'raises NotImplementedError when not implemented' do
        expect { incomplete_instance.send(:prompt_context) }
          .to raise_error(NotImplementedError, /must implement prompt_context/)
      end
    end
  end
end
