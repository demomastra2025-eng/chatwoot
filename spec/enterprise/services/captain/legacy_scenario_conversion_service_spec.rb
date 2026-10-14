require 'rails_helper'

RSpec.describe Captain::LegacyScenarioConversionService do
  include ActiveJob::TestHelper

  let(:account) { create(:account) }
  let(:parent) { create(:captain_assistant, account: account, description: 'Parent main instruction') }
  let!(:scenario) { create(:captain_scenario, assistant: parent, account: account, instruction: 'Only the scenario instruction') }

  def converted_agent(legacy_scenario = scenario)
    Captain::Assistant.find_by!(legacy_scenario_id: legacy_scenario.id)
  end

  it 'keeps stable mappings and preserves later agent edits and removed routes when rerun' do
    converter = described_class.new
    expect { converter.perform }.to change(Captain::Assistant, :count).by(1)
    agent = converted_agent
    agent.update!(description: 'Edited independent instruction')
    agent.outgoing_agent_handoffs.delete_all

    expect { converter.perform }.not_to change(Captain::Assistant, :count)
    expect(converted_agent.id).to eq(agent.id)
    expect(converted_agent.description).to eq('Edited independent instruction')
    expect(converted_agent.handoff_agent_ids).to be_empty
    expect(Captain::Scenario.find(scenario.id).instruction).to eq('Only the scenario instruction')
  end

  it 'copies the own prompt, capability settings, rules and own references without the parent main prompt' do
    parent.update_columns(
      description: 'Parent secret [Parent tool](tool://parent_only) [Parent field](field://contact.email)',
      config: {
        'model' => 'vendor/saved-model', 'temperature' => 0.35, 'feature_image_understanding' => true,
        'safety_settings' => { 'prompt_injection_action' => 'block' },
        'context_access' => { 'contact' => { 'enabled' => true, 'field_ids' => ['contact.name'] } },
        'tool_access' => { 'agent' => { 'enabled' => true, 'tool_ids' => %w[handoff parent_only] } }
      },
      response_guidelines: ['Keep answers brief'], guardrails: ['Keep private data private']
    )
    scenario.update_columns(instruction: 'Own [Own tool](tool://own_tool) [Name](field://contact.name)', tools: ['own_tool'])

    described_class.new.perform

    agent = converted_agent
    expect(agent.description).to eq("#{scenario.reload.instruction}\n\nKeep answers brief\n\nKeep private data private")
    expect(agent.description).not_to include('Parent secret')
    expect(agent.routing_description).to eq(scenario.description)
    expect(agent.config).to include('model' => 'vendor/saved-model', 'temperature' => 0.35, 'feature_image_understanding' => true)
    expect(agent.config['safety_settings']).to eq('prompt_injection_action' => 'block')
    expect(agent.config.dig('tool_access', 'agent', 'tool_ids')).to contain_exactly('own_tool', 'handoff')
    expect(agent.response_guidelines).to eq([])
    expect(agent.guardrails).to eq([])
    expect(agent.config).not_to have_key('rules')
    expect(agent.updated_at).to eq(scenario.updated_at)
    report = agent.config.fetch('legacy_scenario_migration')
    expect(report['explicit_tool_ids']).to eq(['own_tool'])
    expect(report['referenced_field_ids']).to eq(['contact.name'])
    expect(report['warnings'].map { |warning| warning['code'] }).to include(
      'parent_prompt_not_copied', 'parent_prompt_tool_dependencies_not_copied', 'parent_prompt_field_dependencies_not_copied'
    )
  end

  it 'reproduces parent and sibling routes, preserves disabled state and filters dormant targets at runtime' do
    sibling = create(:captain_scenario, assistant: parent, account: account, enabled: false)
    described_class.new.perform
    agent = converted_agent
    dormant = converted_agent(sibling)

    expect(dormant).not_to be_active
    expect(parent.reload.handoff_agent_ids).to contain_exactly(agent.id, dormant.id)
    expect(agent.handoff_agent_ids).to contain_exactly(parent.id, dormant.id)
    expect(dormant.handoff_agent_ids).to contain_exactly(parent.id, agent.id)
    expect(parent.handoff_targets).to contain_exactly(agent)
    expect(agent.handoff_targets).to contain_exactly(parent)
  end

  it 'does not grant a handoff tool when the parent tool scope is disabled' do
    parent.update_columns(config: { 'tool_access' => { 'agent' => { 'enabled' => false, 'tool_ids' => [] } } })

    described_class.new.perform

    expect(converted_agent.config.dig('tool_access', 'agent')).to eq('enabled' => false, 'tool_ids' => [])
  end

  it 'preserves the effective default capabilities without importing unrelated selected parent tools' do
    parent.update_columns(config: {
                            'feature_faq' => true, 'feature_web' => true,
                            'tool_access' => { 'agent' => { 'enabled' => true, 'tool_ids' => %w[faq_lookup web_search handoff parent_only] } },
                            'follow_up_settings' => {
                              'enabled' => true,
                              'steps' => [{ 'mode' => 'static', 'message' => 'Check in', 'delay_seconds' => 60 }]
                            }
                          })

    described_class.new.perform

    expect(converted_agent.config.dig('tool_access', 'agent', 'tool_ids')).to contain_exactly('faq_lookup', 'web_search', 'handoff')
    expect(converted_agent.config['follow_up_settings']).to eq(parent.reload.config['follow_up_settings'])
  end

  it 'uses callback free records and never schedules jobs or reads provider configuration' do
    expect(Llm::Config).not_to receive(:model_for)
    expect(Llm::Config).not_to receive(:context)
    expect(Captain::Assistant).not_to receive(:create!)

    expect { described_class.new.perform }.not_to(change { enqueued_jobs.size })
  end

  it 'preserves mentioned private notes without enabling unchecked capability tools' do
    parent.update_columns(config: { 'tool_access' => { 'agent' => { 'enabled' => true, 'tool_ids' => ['handoff'] } } })
    scenario.update_columns(instruction: 'Use [FAQ](tool://faq_lookup) and [Private note](tool://add_private_note).',
                            tools: %w[faq_lookup add_private_note cancel_response])
    described_class.new.perform
    expect(converted_agent.config.dig('tool_access', 'agent', 'tool_ids')).to contain_exactly('handoff', 'add_private_note')
    expect(converted_agent.allowed_agent_tool_ids).to contain_exactly('handoff', 'faq_lookup', 'resolve_conversation', 'add_private_note')
    expect(converted_agent.allowed_agent_tool_ids).not_to include('cancel_response')
  end

  it 'retains a scenario with mismatched workspace ownership without copying it across accounts' do
    scenario.update_columns(account_id: create(:account).id)

    report = described_class.new.perform

    expect(report[:skipped]).to include(hash_including(scenario_id: scenario.id, warning: 'parent_missing_or_account_mismatch'))
    expect(Captain::Assistant.where(legacy_scenario_id: scenario.id)).not_to exist
    expect(Captain::Scenario.where(id: scenario.id)).to exist
  end

  it 'keeps the historical scenario and independent agent after the former parent is deleted' do
    described_class.new.perform
    agent_id = converted_agent.id

    parent.destroy!

    expect(Captain::Scenario.find(scenario.id).assistant_id).to be_nil
    expect(Captain::Assistant.find(agent_id).legacy_scenario_id).to eq(scenario.id)
  end
end
