require 'rails_helper'

RSpec.describe AutomationRules::ContactCondition do
  describe '.normalize_id' do
    it 'accepts positive integers and strings of digits' do
      expect(described_class.normalize_id(7)).to eq(7)
      expect(described_class.normalize_id('7')).to eq(7)
      expect(described_class.normalize_id('1234567890123')).to eq(1_234_567_890_123)
    end

    it 'rejects everything else' do
      [0, -1, '0', '-3', '07', ' 7', '7 ', '7.0', 7.0, 7.5, '1e3', 'abc', '', nil, true, [7], { id: 7 }, 10**30, (2**63)].each do |value|
        expect(described_class.normalize_id(value)).to be_nil, "expected #{value.inspect} to be rejected"
      end
    end

    it 'accepts the largest bigint id' do
      expect(described_class.normalize_id((2**63) - 1)).to eq((2**63) - 1)
    end
  end

  describe '.normalize_ids' do
    it 'keeps the readable ids once, in order' do
      expect(described_class.normalize_ids([3, '3', 'x', 5, nil, '5.5', 1])).to eq([3, 5, 1])
    end

    it 'treats a missing or scalar value as a list' do
      expect(described_class.normalize_ids(nil)).to eq([])
      expect(described_class.normalize_ids('9')).to eq([9])
    end
  end

  describe '.ids_well_formed?' do
    it 'needs a list of 1..MAX_VALUES ids' do
      expect(described_class.ids_well_formed?([1, '2'])).to be(true)
      expect(described_class.ids_well_formed?(Array.new(described_class::MAX_VALUES) { |i| i + 1 })).to be(true)
      expect(described_class.ids_well_formed?(Array.new(described_class::MAX_VALUES + 1) { |i| i + 1 })).to be(false)
    end

    it 'rejects empty lists, scalars and lists with a bad value' do
      [[], '1', 1, nil, [1, 'x'], [1, nil], [[1]]].each do |values|
        expect(described_class.ids_well_formed?(values)).to be(false), "expected #{values.inspect} to be rejected"
      end
    end
  end

  describe '.contact_condition?' do
    it 'recognises the contact condition only when it is not a custom attribute' do
      expect(described_class.contact_condition?({ 'attribute_key' => 'contact_id' })).to be(true)
      expect(described_class.contact_condition?({ 'attribute_key' => 'contact_id', 'custom_attribute_type' => '' })).to be(true)
      expect(described_class.contact_condition?({ 'attribute_key' => 'contact_id', 'custom_attribute_type' => 'contact_attribute' })).to be(false)
      expect(described_class.contact_condition?({ 'attribute_key' => 'status' })).to be(false)
      expect(described_class.contact_condition?('contact_id')).to be(false)
      expect(described_class.contact_condition?(nil)).to be(false)
    end
  end

  describe '.conversation_sql' do
    it 'lists the readable ids of the account for "is"' do
      sql, binds = described_class.conversation_sql('equal_to', [3, '4', 'x'], 'AND', 2, 9)

      expect(sql).to eq(' (contacts.account_id = :account_2 AND contacts.id IN (:value_2)) AND ')
      expect(binds).to eq('account_2' => 9, 'value_2' => [3, 4])
    end

    it 'negates the list for "is not", keeping conversations without a contact' do
      sql, binds = described_class.conversation_sql('not_equal_to', [3], nil, 0, 9)

      expect(sql).to eq(' NOT COALESCE((contacts.account_id = :account_0 AND contacts.id IN (:value_0)), FALSE)  ')
      expect(binds).to eq('account_0' => 9, 'value_0' => [3])
    end

    it 'matches nothing for an unreadable list or another operator' do
      [['equal_to', []], ['not_equal_to', ['x']], ['contains', [3]], [nil, [3]]].each do |operator, values|
        sql, binds = described_class.conversation_sql(operator, values, 'OR', 1, 9)

        expect(sql).to eq(' 1=0 OR ')
        expect(binds).to eq({})
      end
    end
  end

  describe '.matches?' do
    it 'makes "is" true and "is not" false when an event contact is listed' do
      expect(described_class.matches?('equal_to', [1, 2], [2, nil])).to be(true)
      expect(described_class.matches?('not_equal_to', [1, 2], [2, nil])).to be(false)
    end

    it 'makes "is" false and "is not" true when no event contact is listed' do
      expect(described_class.matches?('equal_to', [1, 2], [3])).to be(false)
      expect(described_class.matches?('not_equal_to', [1, 2], [3])).to be(true)
      expect(described_class.matches?('not_equal_to', [1, 2], [nil, nil])).to be(true)
    end

    it 'never matches an empty list or another operator' do
      expect(described_class.matches?('equal_to', [], [1])).to be(false)
      expect(described_class.matches?('not_equal_to', [], [1])).to be(false)
      expect(described_class.matches?('contains', [1], [1])).to be(false)
    end
  end
end
