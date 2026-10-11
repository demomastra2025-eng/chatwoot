require 'rails_helper'

RSpec.describe Captain::Assistant, type: :model do
  let(:assistant) do
    build(:captain_assistant, legacy_scenario_id: 42, description: 'Own instructions', config: {
      'tool_access' => { 'agent' => { 'enabled' => true, 'tool_ids' => ['own_tool'] } },
      'legacy_scenario_migration' => { 'explicit_tool_ids' => %w[own_tool parent_only] }
    })
  end

  before do
    allow(assistant).to receive(:available_agent_tools).and_return([{ id: 'own_tool' }, { id: 'parent_only' }])
    allow(assistant).to receive(:available_assistant_tools).and_return([])
  end

  it 'preserves the own scenario tool as a runtime and prompt reference without importing parent-only selections' do
    expect(assistant.allowed_agent_tool_ids).to eq(['own_tool'])
    expect(assistant.send(:prompt_referenced_tool_ids_for_template, :assistant)).to eq(['own_tool'])
  end

  it 'lets the independent settings disable the preserved tool' do
    assistant.config['tool_access']['agent']['tool_ids'] = []

    expect(assistant.allowed_agent_tool_ids).to be_empty
    expect(assistant.send(:prompt_referenced_tool_ids_for_template, :assistant)).to be_empty
  end

  it 'keeps explicitly selected tools but ignores migration metadata without a legacy mapping' do
    assistant.legacy_scenario_id = nil

    expect(assistant.allowed_agent_tool_ids).to eq(['own_tool'])
    expect(assistant.send(:prompt_referenced_tool_ids_for_template, :assistant)).to be_empty
  end
end
