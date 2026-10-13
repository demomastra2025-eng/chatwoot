# frozen_string_literal: true

require 'rails_helper'

# The customer-facing agent sees short English tool texts (config/captain/agent_tool_texts.yml) instead of the registry and
# Copilot class texts; the registry, MCP, voice and the UI keep theirs.
# Test tool constants intentionally live with the examples that exercise them.
# rubocop:disable Lint/ConstantDefinitionInBlock
RSpec.describe Captain::Runtime::ToolWrapper do
  class ToolWrapperAgentTextsSpecFakeTool < Captain::Runtime::Tool
    param :query, type: :string, desc: 'Own query text', required: false
    param :include_inactive, type: :boolean, desc: 'Own inactive text', required: false
    params(
      type: 'object',
      properties: { query: { type: 'string', description: 'Own query text' }, include_inactive: { type: 'boolean' } },
      required: [],
      additionalProperties: false
    )

    def name
      'search_scheduling_services'
    end

    def description
      'Own long description of a tool that is not a registry tool'
    end

    def perform(_tool_context, **params)
      params.to_json
    end
  end

  let(:assistant) { create(:captain_assistant) }
  let(:run_context) { Captain::Runtime::RunContext.new({ state: {} }, callbacks: {}) }

  def wrapper_for(tool_id)
    tool = Captain::ToolCatalog.build_tool({ id: tool_id }, assistant: assistant, scope_name: Captain::ToolAccess::SCOPE_AGENT)
    described_class.new(tool, run_context)
  end

  def texts(tool_id)
    Captain::Runtime::AgentToolTexts.for_tool(tool_id)
  end

  describe 'description and parameter texts' do
    it 'shows the model the short English description of an account-tool adapter' do
      wrapper = wrapper_for('search_scheduling_services')

      expect(wrapper.description).to eq(texts('search_scheduling_services').description)
      %w[limit offset query].each do |name|
        expect(wrapper.params_schema.dig('properties', name, 'description')).to eq(texts('search_scheduling_services').params.fetch(name))
      end
      expect(wrapper.params_schema.dig('properties', 'query', 'description')).not_to match(/\p{Cyrillic}/)
    end

    it 'shows the model the short English texts of a direct tool and keeps the validation of its required fields' do
      wrapper = wrapper_for('create_appointment')

      expect(wrapper.description).to eq(texts('create_appointment').description)
      expect(wrapper.params_schema.dig('properties', 'resource_id', 'description')).to eq('Specialist ID from search_scheduling_resources.')
      %w[custom_attributes patient].each do |name|
        expect(wrapper.params_schema.dig('properties', name, 'description')).to eq(texts('create_appointment').params.fetch(name))
      end
      expect(wrapper.params_schema['required']).to include('resource_id', 'starts_at')
    end

    it 'leaves the long registry text and the suffix phrases out of what the model sees' do
      wrapper = wrapper_for('create_appointment')
      shown = [wrapper.description, *wrapper.params_schema['properties'].values.pluck('description')].compact.join(' ')

      expect(shown).not_to match(/Medelement|MedElement|cabinet|reception ID|omit the key|Never guess an ID|placeholder/i)
    end

    it 'keeps a null for an optional value and the lower bound of an id, without text appended to the description' do
      properties = wrapper_for('create_appointment').params_schema['properties']

      expect(properties.dig('service_id', 'type')).to contain_exactly('number', 'null')
      expect(properties.dig('service_id', 'minimum')).to eq(1)
      expect(properties.dig('service_id', 'description')).to eq('Service ID from search_scheduling_services.')
      expect(properties.dig('resource_id', 'type')).to eq('number')
      expect(properties.dig('resource_id', 'minimum')).to eq(1)
      expect(properties.dig('resource_id', 'description')).to eq('Specialist ID from search_scheduling_resources.')
    end

    it 'gives the provider the short texts and leaves the hidden options of the specialist search out' do
      provider_tool = RubyLLM::Providers::OpenAI::Tools.tool_for(wrapper_for('search_scheduling_resources'))
      properties = provider_tool.dig(:function, :parameters, 'properties')

      expect(provider_tool.dig(:function, :description)).to eq(texts('search_scheduling_resources').description)
      expect(properties.dig('query', 'description')).to eq(texts('search_scheduling_resources').params['query'])
      expect(properties).not_to have_key('include_inactive')
      expect(properties).not_to have_key('search_by')
    end

    it 'keeps its own text for a built-in tool without an entry' do
      allow(Captain::Runtime::AgentToolTexts).to receive(:for_tool).and_call_original
      allow(Captain::Runtime::AgentToolTexts).to receive(:for_tool).with('faq_lookup').and_return(nil)
      wrapper = wrapper_for('faq_lookup')

      expect(wrapper.description).to eq(Captain::Tools::FaqLookupTool.description)
      expect(wrapper.params_schema.dig('properties', 'query', 'description')).to eq('The question or topic to search for in the FAQ database')
    end

    it 'keeps its own text for a parameter without an entry' do
      allow(Captain::Runtime::AgentToolTexts).to receive(:for_tool).and_call_original
      entry = Captain::Runtime::AgentToolTexts::Entry.new(
        description: 'Short', params: { 'query' => 'Short query' }, hidden_params: []
      )
      allow(Captain::Runtime::AgentToolTexts).to receive(:for_tool).with('search_scheduling_services').and_return(entry)
      wrapper = wrapper_for('search_scheduling_services')

      expect(wrapper.params_schema.dig('properties', 'query', 'description')).to eq('Short query')
      expect(wrapper.params_schema.dig('properties', 'limit', 'description')).to eq('Maximum number of services to return')
    end

    it 'does not touch a tool that is not a built-in registry tool, whatever its name is' do
      wrapper = described_class.new(ToolWrapperAgentTextsSpecFakeTool.new, run_context)

      expect(wrapper.description).to eq('Own long description of a tool that is not a registry tool')
      expect(wrapper.params_schema.dig('properties', 'query', 'description')).to eq('Own query text')
      expect(wrapper.params_schema['properties']).to have_key('include_inactive')
    end

    it 'does not let an MCP or skill-script name reach the override' do
      tool = Captain::Tools::McpTool.allocate
      allow(tool).to receive_messages(name: 'search_scheduling_services', description: 'Server text')
      wrapper = described_class.new(tool, run_context)

      expect(wrapper.description).to eq('Server text')
    end
  end

  describe 'hidden parameters' do
    it 'removes the deal links of create_appointment from the model schema' do
      properties = wrapper_for('create_appointment').params_schema['properties']

      expect(properties.keys).not_to include('crm_deal_id', 'crm_pipeline_id')
      expect(properties.keys).to include('resource_id', 'starts_at', 'patient', 'custom_attributes')
    end

    it 'removes include_inactive from the catalog tools' do
      %w[search_scheduling_services list_scheduling_resources search_scheduling_resources].each do |tool_id|
        expect(wrapper_for(tool_id).params_schema['properties']).not_to have_key('include_inactive')
      end
    end

    it 'removes search_by from the specialist search: it always searches names and specialties' do
      expect(wrapper_for('search_scheduling_resources').params_schema['properties']).not_to have_key('search_by')
      expect(wrapper_for('search_scheduling_resources').params_schema['properties'].keys).to include('query', 'service_id', 'limit', 'offset')
    end

    it 'keeps the hidden parameters in the tool itself and in the schema arguments are validated against' do
      wrapper = wrapper_for('create_appointment')

      expect(wrapper.send(:validation_params_schema)['properties'].keys).to include('crm_deal_id', 'crm_pipeline_id')
      expect(wrapper.instance_variable_get(:@tool).params_schema.deep_stringify_keys['properties'].keys).to include('crm_deal_id')
    end

    it 'drops a hidden parameter that is sent anyway, even an invalid one, before the tool runs' do
      wrapper = wrapper_for('create_appointment')

      normalized = wrapper.send(:normalize_args, resource_id: 1, starts_at: '2026-10-14T10:30', crm_deal_id: 0, crm_pipeline_id: 999_999)

      expect(normalized).to eq(resource_id: 1, starts_at: '2026-10-14T10:30')
    end

    it 'drops include_inactive from a catalog search before the tool runs' do
      wrapper = wrapper_for('search_scheduling_services')

      expect(wrapper.send(:normalize_args, query: 'терапевт', include_inactive: true)).to eq(query: 'терапевт')
    end

    it 'drops search_by from a specialist search before the tool runs, so the search covers names and specialties' do
      wrapper = wrapper_for('search_scheduling_resources')

      expect(wrapper.send(:normalize_args, query: 'хирург', search_by: 'name')).to eq(query: 'хирург')
    end

    it 'asks send_message_to_conversation for the conversation ID and hides the parameters the patient scope always denies' do
      properties = wrapper_for('send_message_to_conversation').params_schema['properties']

      expect(properties.dig('conversation_id', 'description')).to eq('Conversation ID from the Patient block.')
      expect(properties.keys).not_to include(
        'communication_thread_id', 'channel_key', 'target_inbox_id', 'target_contact_inbox_id', 'attachment_ids'
      )
      expect(properties.keys).to include('content', 'artifact_ids', 'private_note', 'template_params', 'in_reply_to_message_id')
    end

    it 'drops a thread or blob parameter of send_message_to_conversation that is sent anyway' do
      wrapper = wrapper_for('send_message_to_conversation')

      normalized = wrapper.send(:normalize_args, conversation_id: 15, content: 'Hi', channel_key: 'inbox:1', attachment_ids: ['signed-blob'])

      expect(normalized).to eq(conversation_id: 15, content: 'Hi')
    end

    it 'does not send the model to a custom-field catalog tool that may not be bound for the account' do
      %w[update_appointment create_deal update_deal create_task update_task].each do |tool_id|
        text = wrapper_for(tool_id).params_schema.dig('properties', 'custom_attributes', 'description')

        expect(text).to be_present
        expect(text).not_to match(/list_\w+_custom_fields/), tool_id
      end
    end

    it 'still rejects an argument the tool does not have' do
      wrapper = wrapper_for('search_scheduling_services')

      expect { wrapper.send(:normalize_args, query: 'терапевт', no_such_argument: true) }
        .to raise_error(described_class::InvalidToolArgumentsError)
    end

    it 'keeps a visible parameter that the tool of the same name has' do
      wrapper = described_class.new(ToolWrapperAgentTextsSpecFakeTool.new, run_context)

      expect(wrapper.send(:normalize_args, query: 'a', include_inactive: true)).to eq(query: 'a', include_inactive: true)
    end
  end
end
# rubocop:enable Lint/ConstantDefinitionInBlock
