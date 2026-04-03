# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Concerns::Agentable do
  let(:dummy_class) do
    Class.new do
      include Concerns::Agentable

      attr_accessor :temperature

      def initialize(name: 'Test Agent', temperature: 0.8)
        @name = name
        @temperature = temperature
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
  let(:mock_agents_agent) { instance_double(Agents::Agent) }
  let(:mock_installation_config) { instance_double(InstallationConfig, value: 'gpt-4-turbo') }

  before do
    allow(Agents::Agent).to receive(:new).and_return(mock_agents_agent)
    allow(InstallationConfig).to receive(:find_by).with(name: 'CAPTAIN_OPEN_AI_MODEL').and_return(mock_installation_config)
    allow(Captain::PromptRenderer).to receive(:render).and_return('rendered_template')
  end

  describe '#agent' do
    it 'creates an Agents::Agent with correct parameters' do
      expect(Agents::Agent).to receive(:new).with(
        name: 'Test Agent',
        instructions: instance_of(Proc),
        tools: [],
        model: 'gpt-4-turbo',
        temperature: 0.8,
        response_schema: Captain::ResponseSchema
      )

      dummy_instance.agent
    end

    it 'converts nil temperature to 0.0' do
      dummy_instance.temperature = nil

      expect(Agents::Agent).to receive(:new).with(
        hash_including(temperature: 0.0)
      )

      dummy_instance.agent
    end

    it 'converts temperature to float' do
      dummy_instance.temperature = '0.5'

      expect(Agents::Agent).to receive(:new).with(
        hash_including(temperature: 0.5)
      )

      dummy_instance.agent
    end
  end

  describe '#agent_instructions' do
    it 'calls Captain::PromptRenderer with base context' do
      expect(Captain::PromptRenderer).to receive(:render).with(
        'dummy_class',
        hash_including(base_key: 'base_value')
      )

      dummy_instance.agent_instructions
    end

    it 'merges context state when provided' do
      context_double = instance_double(Agents::RunContext,
                                       context: {
                                         state: {
                                           assistant_config: { 'feature_contact_attributes' => true },
                                           conversation: { id: 123 },
                                           contact: { name: 'John' }
                                         }
                                       })

      expected_context = {
        base_key: 'base_value',
        conversation: { id: 123 },
        contact: { name: 'John' },
        campaign: {}
      }

      expect(Captain::PromptRenderer).to receive(:render).with(
        'dummy_class',
        hash_including(expected_context)
      )

      dummy_instance.agent_instructions(context_double)
    end

    it 'derives visible fields from raw state when prompt_context is absent' do
      context_double = instance_double(Agents::RunContext,
                                       context: {
                                         state: {
                                           assistant_config: { 'feature_contact_attributes' => true },
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
      context_double = instance_double(Agents::RunContext,
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
      context_double = instance_double(Agents::RunContext,
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
          deal_visible_fields: ['stage_name'],
          task_visible_fields: ['status_name'],
          appointment_visible_fields: ['status']
        )
      )

      dummy_instance.agent_instructions(context_double)
    end

    it 'handles context without state' do
      context_double = instance_double(Agents::RunContext, context: {})

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
    it 'returns value from InstallationConfig when present' do
      expect(dummy_instance.send(:agent_model)).to eq('gpt-4-turbo')
    end

    it 'returns default model when config not found' do
      allow(InstallationConfig).to receive(:find_by).and_return(nil)

      expect(dummy_instance.send(:agent_model)).to eq('gpt-4.1')
    end

    it 'returns default model when config value is nil' do
      allow(mock_installation_config).to receive(:value).and_return(nil)

      expect(dummy_instance.send(:agent_model)).to eq('gpt-4.1')
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
