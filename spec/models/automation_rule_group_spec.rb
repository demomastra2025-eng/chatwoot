require 'rails_helper'

RSpec.describe AutomationRuleGroup do
  it 'builds a valid group from the factory' do
    expect(build(:automation_rule_group)).to be_valid
  end

  it 'rejects unsupported event names' do
    group = build(:automation_rule_group, event_name: 'unknown_event')

    expect(group).not_to be_valid
    expect(group.errors[:event_name]).to be_present
  end
end
