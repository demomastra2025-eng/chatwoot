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
