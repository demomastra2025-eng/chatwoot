# frozen_string_literal: true

require 'rails_helper'

# Custom safety rules live in the workspace AI settings (Captain::AccountSettings,
# section "safety"), where Captain::AccountSettingsValidation checks them. A
# rule list left in an agent's config['safety_settings'] is legacy data: it is
# neither read nor validated, so it can never block saving the agent.
RSpec.describe Captain::Assistant, type: :model do
  let(:account) { create(:account) }
  let(:rule) do
    { 'id' => 'b21f4133-85d1-4d56-9bd5-d93aaef569b4', 'name' => 'Urgent request', 'direction' => 'input',
      'instruction' => 'The customer describes an urgent situation.', 'action' => 'handoff', 'enabled' => true }
  end

  def assistant_with_rules(rules)
    build(:captain_assistant, account: account, config: { 'safety_settings' => { 'custom_rules' => rules } })
  end

  it 'keeps a valid legacy rule list as it was stored' do
    rules = [rule.merge('enabled' => false), rule.merge('id' => 'second', 'direction' => 'output', 'action' => 'rewrite')]
    assistant = assistant_with_rules(rules)

    expect(assistant).to be_valid
    expect(assistant.config.dig('safety_settings', 'custom_rules')).to eq(rules)
  end

  [nil, 'rules', {}, [true], [{ 'id' => 'none' }]].each do |value|
    it "does not reject an agent because of a malformed legacy rule list (#{value.inspect})" do
      assistant = assistant_with_rules(value)

      expect(assistant).to be_valid
      expect { assistant.save! }.not_to raise_error
      expect(assistant.reload.config.dig('safety_settings', 'custom_rules')).to eq(value)
    end
  end

  it 'reads a legacy snapshot of malformed safety data without raising' do
    assistant = create(:captain_assistant, account: account,
                                           config: { 'safety_settings' => { 'custom_rules' => ['rules', rule] } })
    broken = create(:captain_assistant, account: account, config: { 'safety_settings' => 'not an object' })

    expect(Captain::AccountSettings.from_assistant(assistant).dig('safety', 'custom_rules').size).to eq(1)
    expect(Captain::AccountSettings.from_assistant(broken).dig('safety', 'custom_rules')).to eq([])
  end

  it 'still validates the rules of the workspace settings' do
    errors = Captain::AccountSettingsValidation.new(Captain::AccountSettings.new(account).defaults)
                                               .errors('safety' => { 'custom_rules' => [rule.merge('action' => 'allow')] })

    expect(errors.pluck(:code)).to include('invalid_value')
  end
end
