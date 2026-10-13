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

  describe '.excludes?' do
    def condition(operator, ids, query_operator = nil)
      { 'attribute_key' => 'contact_id', 'filter_operator' => operator, 'values' => ids, 'query_operator' => query_operator }
    end

    def other(query_operator = nil)
      { 'attribute_key' => 'status', 'filter_operator' => 'equal_to', 'values' => ['open'], 'query_operator' => query_operator }
    end

    it 'excludes a contact an "is not" condition lists, whatever the other conditions say' do
      expect(described_class.excludes?([other('AND'), condition('not_equal_to', [3, 4])], [4])).to be(true)
      expect(described_class.excludes?([condition('not_equal_to', ['3'])], [nil, 3])).to be(true)
    end

    it 'does not exclude contacts the list does not name' do
      expect(described_class.excludes?([condition('not_equal_to', [3])], [4, nil])).to be(false)
      expect(described_class.excludes?([condition('not_equal_to', [3])], [nil])).to be(false)
      expect(described_class.excludes?([condition('not_equal_to', [3])], [])).to be(false)
    end

    it 'reads an "is" list or a rule without contact conditions as no exclusion' do
      expect(described_class.excludes?([condition('equal_to', [3])], [4])).to be(false)
      expect(described_class.excludes?([other], [3])).to be(false)
      expect(described_class.excludes?([], [3])).to be(false)
      expect(described_class.excludes?(nil, [3])).to be(false)
    end

    it 'needs the contact excluded in every OR group' do
      only_first_group = [condition('not_equal_to', [3], 'OR'), other]
      both_groups = [condition('not_equal_to', [3], 'OR'), other('AND'), condition('not_equal_to', [3, 5])]

      expect(described_class.excludes?(only_first_group, [3])).to be(false)
      expect(described_class.excludes?(both_groups, [3])).to be(true)
      expect(described_class.excludes?(both_groups, [5])).to be(false)
    end

    it 'does not take a custom attribute called contact_id for a contact list' do
      custom = condition('not_equal_to', [3]).merge('custom_attribute_type' => 'contact_attribute')

      expect(described_class.excludes?([custom], [3])).to be(false)
    end
  end

  describe '.excluded_ids' do
    it 'collects the ids of the "is not" lists only' do
      conditions = [
        { 'attribute_key' => 'contact_id', 'filter_operator' => 'not_equal_to', 'values' => [3, '4'], 'query_operator' => 'OR' },
        { 'attribute_key' => 'contact_id', 'filter_operator' => 'equal_to', 'values' => [9], 'query_operator' => nil }
      ]

      expect(described_class.excluded_ids(conditions)).to eq([3, 4])
      expect(described_class.excluded_ids(nil)).to eq([])
    end
  end

  describe '.replace_id' do
    it 'swaps one id for another and keeps an id that ends up twice once' do
      expect(described_class.replace_id([1, '2', 3], 2, 5)).to eq([1, 5, 3])
      expect(described_class.replace_id([1, 2], 2, 1)).to eq([1])
      expect(described_class.replace_id(['2', 2], 2, 7)).to eq([7])
    end

    it 'leaves values without the id as they are' do
      expect(described_class.replace_id([1, '3', 3], 2, 5)).to eq([1, '3', 3])
      expect(described_class.replace_id(nil, 2, 5)).to eq([])
    end
  end

  describe '.contact_ids_of' do
    let(:account) { create(:account) }

    it 'reads the contact of a conversation' do
      conversation = create(:conversation, account: account)

      expect(described_class.contact_ids_of(conversation)).to eq([conversation.contact_id])
    end

    it 'reads the booking contact and the patient card of an appointment' do
      account.enable_features!('scheduling')
      patient = create(:contact, account: account)
      appointment = create(:scheduling_appointment, account: account, patient_contact: patient)

      expect(described_class.contact_ids_of(appointment)).to contain_exactly(appointment.contact_id, patient.id)
    end

    it 'reads every contact of a deal and the contacts of the deal of a task' do
      account.enable_features!('crm_deals', 'crm_tasks')
      deal = create(:crm_deal, account: account)
      first = create(:crm_deal_contact, deal: deal, primary: true)
      second = create(:crm_deal_contact, deal: deal)
      task = create(:crm_task, account: account, deal: deal)
      unlinked_task = create(:crm_task, account: account)

      expect(described_class.contact_ids_of(deal)).to contain_exactly(first.contact_id, second.contact_id)
      expect(described_class.contact_ids_of(task)).to contain_exactly(first.contact_id, second.contact_id)
      expect(described_class.contact_ids_of(unlinked_task)).to eq([])
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
