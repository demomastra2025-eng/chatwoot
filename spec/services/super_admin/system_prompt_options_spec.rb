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
