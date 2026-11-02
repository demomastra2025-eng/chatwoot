require 'rails_helper'

RSpec.describe Captain::ToolAccessMigrationPlan do
  it 'reports actual additions and removals on every binding path without mutating pending attributes' do
    assistant = create(:captain_assistant, :legacy, usage_mode: 'internal_assistant', config: { 'tool_access' => {
                         'agent' => { 'enabled' => true, 'tool_ids' => ['add_private_note'] },
                         'assistant' => { 'enabled' => false, 'tool_ids' => [] }
                       } })
    assistant.name = 'Unsaved business edit'
    original = assistant.attributes.deep_dup
    changes = assistant.changes.deep_dup
    scopes = {
      'agent' => { enabled: true, proposed_tool_ids: ['add_contact_note'] },
      'assistant' => { enabled: false, proposed_tool_ids: [] }
    }

    differences = Captain::CapabilitySurfaces.compare(assistant, scopes)

    %i[allowed_agent prompt_agent voice mcp_agent_catalog mcp_agent_direct].each do |surface|
      expect(differences.fetch(surface)).to eq(added: ['add_contact_note'], removed: ['add_private_note'])
    end
    expect(assistant.attributes).to eq(original)
    expect(assistant.changes).to eq(changes)
  end

  it 'preserves both scopes, dormant grants, prompt references and disabled scopes without mutation' do
    assistant = create(:captain_assistant, :legacy, usage_mode: 'internal_assistant', config: {
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
