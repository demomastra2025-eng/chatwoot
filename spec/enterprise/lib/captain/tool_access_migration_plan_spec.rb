require 'rails_helper'

RSpec.describe Captain::ToolAccessMigrationPlan do
  it 'preserves both scopes, dormant grants, prompt references and disabled scopes without mutation' do
    assistant = create(:captain_assistant, usage_mode: 'internal_assistant', config: {
                         'tool_access' => {
                           'agent' => { 'enabled' => true, 'tool_ids' => ['old_unavailable_tool'] },
                           'assistant' => { 'enabled' => false, 'tool_ids' => ['get_contact'] },
                           'future_scope' => { 'tool_ids' => ['future_tool'] }
                         }
                       })
    allow(assistant).to receive(:referenced_tool_ids_for_scope).with('agent').and_return(['add_private_note'])
    allow(assistant).to receive(:referenced_tool_ids_for_scope).with('assistant').and_return(['get_contact'])
    original = assistant.attributes.deep_dup

    plan = described_class.for(assistant)

    expect(plan).to include(status: 'blocked', blockers: include('unknown_scopes', 'unknown_tool_ids'))
    expect(plan[:scopes]['agent'][:proposed_tool_ids]).to include('old_unavailable_tool', 'add_private_note')
    expect(plan[:scopes]['agent'][:unknown_tool_ids]).to include('old_unavailable_tool')
    expect(plan[:scopes]['assistant']).to include(enabled: false, proposed_tool_ids: ['get_contact'])
    expect(assistant.reload.attributes).to eq(original)
  end
end
