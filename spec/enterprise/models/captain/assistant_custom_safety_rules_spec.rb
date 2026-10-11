# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::Assistant, type: :model do
  let(:account) { create(:account) }
  let(:rule) do
    { 'id' => 'b21f4133-85d1-4d56-9bd5-d93aaef569b4', 'name' => 'Urgent request', 'direction' => 'input',
      'instruction' => 'The customer describes an urgent situation.', 'action' => 'handoff', 'enabled' => true }
  end

  def assistant_with_rules(rules)
    build(:captain_assistant, account: account, config: { 'safety_settings' => { 'custom_rules' => rules } })
  end

  def expect_violation(assistant, path:, code:)
    expect(assistant).not_to be_valid
    expect(assistant.errors.details[:config]).to include(error: :invalid_custom_safety_rules, path: path, code: code)
  end

  it 'accepts an empty list and preserves disabled rules and the supplied priority' do
    rules = [rule.merge('enabled' => false), rule.merge('id' => 'second', 'direction' => 'output', 'action' => 'rewrite')]
    assistant = assistant_with_rules(rules)

    expect(assistant_with_rules([])).to be_valid
    expect(assistant).to be_valid
    expect(assistant.config.dig('safety_settings', 'custom_rules')).to eq(rules)
  end

  it 'accepts all size boundaries without truncating configured text' do
    boundary = rule.merge('name' => 'n' * 120, 'instruction' => 'i' * 2000, 'message' => 'm' * 2000)
    rules = Array.new(20) { |index| boundary.merge('id' => "rule_#{index}") }
    assistant = assistant_with_rules(rules)

    expect(assistant).to be_valid
    expect(assistant.config.dig('safety_settings', 'custom_rules')).to eq(rules)
  end

  [nil, 'rules', {}].each do |value|
    it "rejects a #{value.class} instead of treating it as an empty rule list" do
      expect_violation(assistant_with_rules(value), path: 'safety_settings.custom_rules', code: 'invalid_type')
    end
  end

  it 'rejects too many rules without dropping the tail' do
    rules = Array.new(21) { |index| rule.merge('id' => "rule_#{index}") }

    expect_violation(assistant_with_rules(rules), path: 'safety_settings.custom_rules', code: 'too_many')
  end

  it 'rejects nonobject entries' do
    expect_violation(assistant_with_rules([true]), path: 'safety_settings.custom_rules[0]', code: 'invalid_type')
  end

  it 'rejects a missing identity and duplicate identities' do
    expect_violation(assistant_with_rules([rule.except('id')]), path: 'safety_settings.custom_rules[0].id', code: 'required')
    expect_violation(assistant_with_rules([rule, rule]), path: 'safety_settings.custom_rules[1].id', code: 'duplicate_id')
  end

  ['none', 'has spaces', 'x' * 65].each do |id|
    it "rejects a reserved or malformed rule identity of length #{id.length}" do
      expect_violation(assistant_with_rules([rule.merge('id' => id)]), path: 'safety_settings.custom_rules[0].id', code: 'invalid_id')
    end
  end

  { 'name' => 120, 'instruction' => 2000, 'message' => 2000 }.each do |field, maximum|
    it "rejects oversized #{field} without normalizing it" do
      expect_violation(assistant_with_rules([rule.merge(field => 'x' * (maximum + 1))]),
                       path: "safety_settings.custom_rules[0].#{field}", code: 'too_long')
    end
  end

  %w[name instruction].each do |field|
    it "rejects a blank #{field}" do
      expect_violation(assistant_with_rules([rule.merge(field => " \n ")]), path: "safety_settings.custom_rules[0].#{field}", code: 'blank')
    end
  end

  it 'rejects coercible enabled values and invalid direction or action values' do
    invalid = { 'enabled' => ['true', 'invalid_type'], 'direction' => ['both', 'invalid_value'], 'action' => ['allow', 'invalid_value'] }
    invalid.each do |field, (value, code)|
      expect_violation(assistant_with_rules([rule.merge(field => value)]), path: "safety_settings.custom_rules[0].#{field}", code: code)
    end
  end

  it 'permits block compatibility but forbids rewriting customer input' do
    expect(assistant_with_rules([rule.merge('action' => 'block')])).to be_valid
    expect_violation(assistant_with_rules([rule.merge('action' => 'rewrite')]), path: 'safety_settings.custom_rules[0].action', code: 'output_only')
  end

  it 'accepts an omitted or empty public message and rejects a null message' do
    expect(assistant_with_rules([rule])).to be_valid
    expect(assistant_with_rules([rule.merge('message' => '')])).to be_valid
    expect_violation(assistant_with_rules([rule.merge('message' => nil)]), path: 'safety_settings.custom_rules[0].message', code: 'invalid_type')
  end

  it 'rejects unsupported rule fields without echoing their potentially sensitive value' do
    assistant = assistant_with_rules([rule.merge('provider_token' => 'private-provider-token')])

    expect_violation(assistant, path: 'safety_settings.custom_rules[0]', code: 'unknown_fields')
    expect(assistant.errors.full_messages.join).not_to include('private-provider-token')
  end
end
