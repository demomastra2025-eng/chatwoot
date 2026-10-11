# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::Assistant::MergeLegacyRulesService do
  let(:assistant) { create(:captain_assistant, description: "Own prompt\n\nKeep  formatting.") }

  def store_legacy_rules(config: {}, guidelines: [], guardrails: [])
    assistant.update_columns(config: assistant.config.merge(config), response_guidelines: guidelines, guardrails: guardrails)
  end

  it 'preserves multiline text and formatting while merging duplicate legacy sources once' do
    text = "Reply steps:\n  - First line\n  - Second line\n\n```text\n  preserve indentation\n```"
    store_legacy_rules(config: { 'rules' => [{ 'id' => 'custom', 'type' => 'response_guideline', 'content' => text }] },
                       guidelines: [text], guardrails: ["Never invent a booking.\nVerify its receipt."])

    described_class.new(assistant: assistant).perform

    expect(assistant.reload.description).to eq("Own prompt\n\nKeep  formatting.\n\n#{text}\n\nNever invent a booking.\nVerify its receipt.")
    expect(assistant.config).not_to have_key('rules')
    expect(assistant.response_guidelines).to eq([])
    expect(assistant.guardrails).to eq([])
  end

  it 'does not duplicate instructions or update the row on replay' do
    store_legacy_rules(guidelines: ['Use a calm tone.'])
    service = described_class.new(assistant: assistant)
    service.perform
    snapshot = assistant.reload.attributes

    service.perform

    expect(assistant.reload.attributes).to eq(snapshot)
    expect(assistant.description.scan('Use a calm tone.').length).to eq(1)
  end

  it 'distinguishes quoted mentions from an already present instruction block' do
    assistant.update_columns(description: 'A customer may say "Use a calm tone."', response_guidelines: ['Use a calm tone.'])

    described_class.new(assistant: assistant).perform

    expect(assistant.reload.description).to eq("A customer may say \"Use a calm tone.\"\n\nUse a calm tone.")
  end

  it 'archives disabled user rules without activating or deleting their text' do
    text = "Disabled instruction\n  with its original indentation."
    store_legacy_rules(config: { 'rules' => [{ 'type' => 'guardrail', 'content' => text, 'enabled' => false }] })

    described_class.new(assistant: assistant).perform

    expect(assistant.reload.description).not_to include(text, '## Archived disabled instructions')
    expect(assistant.agent_instructions).not_to include(text)
    expect(assistant.config.dig(described_class::MIGRATION_KEY, 'archived_rules')).to eq([text])
    described_class.new(assistant: assistant).perform
    expect(assistant.reload.config.dig(described_class::MIGRATION_KEY, 'archived_rules')).to eq([text])
  end

  it 'drops generated default boilerplate and preserves changed or editable system rule text' do
    default = Captain::Assistant::DEFAULT_SYSTEM_RULES.first
    store_legacy_rules(config: { 'rules' => [
                        { 'id' => default[:id], 'type' => 'system', 'content' => default[:content], 'editable' => false },
                        { 'id' => 'custom', 'type' => 'system', 'content' => 'Speak in the company voice.', 'editable' => true },
                        { 'id' => 'be_concise', 'type' => 'system', 'content' => 'Explain each requested step.', 'editable' => false }
                      ] })

    described_class.new(assistant: assistant).perform

    expect(assistant.reload.description).not_to include(default[:content])
    expect(assistant.description).to include('Speak in the company voice.', 'Explain each requested step.')
  end

  it 'keeps a converted standalone agent own rules without copying its parent prompt' do
    parent = create(:captain_assistant, account: assistant.account, description: 'PARENT PRIVATE PROMPT')
    scenario = create(:captain_scenario, account: assistant.account, assistant: parent)
    assistant.update_columns(legacy_scenario_id: scenario.id, response_guidelines: ["Own old rule\nSecond line"])

    described_class.new(assistant: assistant).perform

    expect(assistant.reload.description).to include('Own prompt', "Own old rule\nSecond line")
    expect(assistant.description).not_to include('PARENT PRIVATE PROMPT')
  end

  it 'preserves oversized migrated prompts and allows editing them without truncation' do
    text = 'x' * (Captain::Assistant::DESCRIPTION_MAX_LENGTH + 1)
    store_legacy_rules(guidelines: [text])

    described_class.new(assistant: assistant).perform

    expect(assistant.reload.description).to include(text)
    expect(assistant.update(description: assistant.description.sub('Own prompt', 'Own Prompt'))).to be(true)
  end

  it 'preserves skill reference labels without loading skill content or script tools' do
    store_legacy_rules(config: { 'skills' => ['workspace-procedure'],
                                'tool_access' => { 'agent' => { 'enabled' => true, 'tool_ids' => %w[handoff skill_script_abc] } } },
                       guidelines: ['Use [Workspace procedure](skill://workspace-procedure).'])
    allow(Captain::SkillCatalog).to receive(:prompt_blocks_for).and_raise('Skills must not be loaded')
    allow(Captain::SkillCatalog).to receive(:script_tools_for).and_raise('Scripts must not be loaded')

    described_class.new(assistant: assistant).perform

    expect(assistant.reload.description).to include('[Workspace procedure](skill://workspace-procedure)')
    expect(assistant.agent_instructions).to include('Use Workspace procedure.')
    expect(assistant.agent_instructions).not_to include('# Loaded Skills', 'skill://')
    expect(assistant.allowed_agent_tools).not_to include(include(provider: 'skill_script'))
    expect(assistant.config).not_to have_key('skills')
    expect(assistant.config.dig('tool_access', 'agent', 'tool_ids')).to eq(['handoff'])
  end

  it 'keeps old script reference text editable without enabling or describing it as a callable tool' do
    assistant.update_columns(description: 'Use [Summary script](tool://skill_script_abc).')
    expect(assistant.update(name: 'Updated agent')).to be(true)
    expect(assistant.agent_instructions).to include('Use Summary script.')
    expect(assistant.agent_instructions).not_to include('`Summary script` tool')
    expect(assistant.allowed_agent_tool_ids).not_to include('skill_script_abc')
  end
end
