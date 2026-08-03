# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::Runtime::ToolWrapper do
  let(:assistant) { create(:captain_assistant) }
  let(:optional_arguments) do
    {
      'search_articles' => %w[category_id],
      'list_deal_stages' => %w[deal_id],
      'search_canned_responses' => %w[query],
      'search_scheduling_resources' => %w[service_id],
      'get_scheduling_resource_availability' => %w[service_id],
      'search_available_slots' => %w[service_id],
      'search_contacts' => %w[email phone_number],
      'search_deals' => %w[pipeline_id stage_id owner_id company_id archived],
      'create_deal' => %w[pipeline_id stage_id win_probability closing_reasons],
      'create_company' => %w[domain],
      'create_task' => %w[deal_id originating_conversation_id],
      'update_deal' => %w[pipeline_id stage_id win_probability closing_reasons],
      'transition_deal_stage' => %w[pipeline_id closing_reasons],
      'search_tasks' => %w[deal_id assignee_id archived],
      'update_task' => %w[title activity_type outcome outcome_note start_at due_at custom_attributes],
      'change_task_status' => %w[status_id],
      'create_touch' => %w[scheduled_at repeat_mode],
      'apply_touch_plan' => %w[touch_plan_id],
      'cancel_touches' => %w[touch_plan_id],
      'archive_touch_plan' => %w[touch_plan_id],
      'search_appointments' => %w[resource_id],
      'create_appointment' => %w[ends_at appointment_type custom_attributes],
      'search_conversations' => %w[status priority labels],
      'assign_conversation' => %w[team_id]
    }
  end
  let(:valid_values_by_type) do
    { 'integer' => 1, 'number' => 1.0, 'boolean' => true, 'array' => [], 'object' => {} }
  end

  it 'keeps omitted optional fields absent across every affected Agent schema and runtime wrapper', :aggregate_failures do
    optional_arguments.each do |tool_id, optional_names|
      tool_class = Captain::ToolRegistry.resolve_agent_tool_class(tool_id)
      expect(tool_class).to be_present, "missing Agent tool class for #{tool_id}"
      next if tool_class.blank?

      wrapper = described_class.new(build_tool(tool_class, tool_id), run_context)
      schema = wrapper.params_schema.deep_stringify_keys
      required = Array(schema['required'])
      arguments = required.index_with { |name| valid_value(schema.fetch('properties').fetch(name)) }
      normalized = wrapper.send(:normalize_args, arguments)

      optional_names.each do |name|
        expect(required).not_to include(name), "#{tool_id}.#{name} must remain optional"
        expect(schema.dig('properties', name)).to be_present, "missing #{tool_id}.#{name} schema"
        expect(schema.dig('properties', name)).not_to have_key('default'), "#{tool_id}.#{name} must not have a wrapper default"
        expect(normalized).not_to have_key(name.to_sym), "#{tool_id}.#{name} was materialized despite omission"
      end
    end
  end

  it 'preserves the dedicated schema and valid arguments for the three RC-02 tools', :aggregate_failures do
    search_args = { name: 'Acme', domain: 'acme.example', limit: 7 }
    expect(wrapper_for('search_companies').send(:normalize_args, search_args)).to eq(search_args)

    company_schema = wrapper_for('create_company').params_schema.deep_stringify_keys
    expect(company_schema['required']).to include('name')
    expect(company_schema['required']).not_to include('domain')

    task_schema = wrapper_for('create_task').params_schema.deep_stringify_keys
    expect(task_schema['required']).to include('title')
    expect(task_schema['required']).not_to include('deal_id', 'originating_conversation_id')
    expect(task_schema.fetch('properties')).to include('deal_id', 'originating_conversation_id')
  end

  def run_context
    Captain::Runtime::RunContext.new({ state: {} }, callbacks: {})
  end

  def wrapper_for(tool_id)
    tool_class = Captain::ToolRegistry.resolve_agent_tool_class(tool_id)
    described_class.new(build_tool(tool_class, tool_id), run_context)
  end

  def build_tool(tool_class, tool_id)
    return tool_class.new(assistant, tool_id: tool_id) if tool_class == Captain::Tools::Agent::AccountToolAdapter

    tool_class.new(assistant)
  end

  def valid_value(schema)
    schema = schema.deep_stringify_keys
    return schema['enum'].first if schema['enum'].present?
    return 1.day.from_now.iso8601 if schema['format'] == 'date-time'

    type = Array(schema['type']).find { |candidate| candidate != 'null' }
    valid_values_by_type.fetch(type, 'value')
  end
end
