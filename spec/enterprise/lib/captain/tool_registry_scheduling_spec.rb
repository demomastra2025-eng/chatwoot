require 'rails_helper'

RSpec.describe 'Captain scheduling tool registry' do
  it 'registers scheduling assistant tools with the expected ids' do
    assistant_tool_ids = Captain::ToolRegistry.tools_for_scope(Captain::ToolAccess::SCOPE_ASSISTANT).pluck(:id)

    expect(assistant_tool_ids).to include(
      'list_scheduling_resources',
      'search_scheduling_resources',
      'get_scheduling_resource_schedule',
      'get_scheduling_resource_availability',
      'search_scheduling_services',
      'search_available_slots',
      'create_appointment'
    )
  end

  it 'lists the patient appointment lookup in the agent catalog' do
    definition = Captain::ToolRegistry.definition_for('list_my_appointments')

    expect(definition.title).to eq('Мои записи')
    expect(definition.allowed_scopes).to eq(Captain::ToolAccess::SCOPE_ORDER)
    expect(definition.tool_class_for(Captain::ToolAccess::SCOPE_AGENT))
      .to eq(Captain::Tools::Agent::AccountToolAdapter)
  end

  it 'keeps appointment mutation tools available to ordered scopes' do
    ordered_scope_ids = Captain::ToolAccess::SCOPE_ORDER.flat_map do |scope|
      Captain::ToolRegistry.tools_for_scope(scope).pluck(:id)
    end.uniq

    expect(ordered_scope_ids).to include(
      'create_appointment',
      'update_appointment',
      'cancel_appointment'
    )
  end
end
