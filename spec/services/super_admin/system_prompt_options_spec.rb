require 'rails_helper'

RSpec.describe SuperAdmin::SystemPromptOptions do
  it 'names the groups in Russian and keeps the stored (English) names as the values' do
    expect(described_class.groups).to eq(
      [['Strict rules', 'Строгие правила'], ['Conversation flow', 'Ход разговора'], ['Restrictions', 'Ограничения'],
       ['Assistant structure', 'Устройство агента'], ['Scenario structure', 'Устройство сценария'], ['Runtime context', 'Контекст диалога']]
    )
  end

  it 'offers the plain rule first and every place of the prompt after it, all in Russian' do
    slots = described_class.slots

    expect(slots.first).to eq(['', 'Обычное правило'])
    expect(slots.map(&:first).drop(1)).to match_array(Captain::Assistant::SYSTEM_TEMPLATE_SLOT_LABELS.keys)
    expect(slots.map(&:last)).to all(match(/\p{Cyrillic}/))
    expect(slots.map(&:last)).not_to include(match(/translation missing/))
  end

  it 'covers the group and the place of every rule the platform ships' do
    Captain::Assistant::DEFAULT_SYSTEM_RULES.each do |rule|
      expect(described_class.group_values).to include(rule[:group])
      expect(described_class.slot_values).to include(rule[:slot]) if rule[:slot]
    end
  end
end

RSpec.describe SuperAdmin::SystemPromptsCheck do
  let(:rule) { { 'id' => 'r1', 'type' => 'system', 'group' => 'Strict rules', 'content' => 'Text', 'slot' => nil } }

  it 'reads the rules of the builder as the five stored fields' do
    entries = described_class.parse([rule.merge('extra' => 'x', 'content' => ' Text ')].to_json)

    expect(entries).to eq([rule])
  end

  it 'drops a rule without text and says nothing of text that is not a list of rules' do
    expect(described_class.parse([rule.merge('content' => '  ')].to_json)).to eq([])
    expect(described_class.parse('')).to eq([])
    expect(described_class.parse('{"a":1}')).to be_nil
    expect(described_class.parse('nope')).to be_nil
  end

  it 'finds no problem in a rule from the lists, or in a rule that keeps its old group and place' do
    expect(described_class.problem([rule.merge('group' => 'Runtime context', 'slot' => 'current_context_usage')], [])).to be_nil
    old = rule.merge('group' => 'Old group', 'slot' => 'old_slot')
    expect(described_class.problem([old], [old])).to be_nil
  end

  it 'names the number of the rule that has a group or a place that is not in the lists' do
    expect(described_class.problem([rule, rule.merge('id' => 'r2', 'group' => 'Typo')], [])).to include('Правило 2', 'группа «Typo»')
    expect(described_class.problem([rule.merge('slot' => 'typo')], [])).to include('Правило 1', 'место в промпте «typo»')
  end
end
