# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SuperAdmin::AuditChanges do
  let(:limit_value) { ->(_key, value, given_back: false) { value.nil? ? (given_back ? 'общее значение' : 'не задан') : value.to_s } }

  def entry(action, changes)
    described_class.new(Struct.new(:action, :audited_changes).new(action, changes), limit_value)
  end

  describe '#limit_lines' do
    it 'tells the limits of a change by a super admin one per line, in the order of the screens', :aggregate_failures do
      limits = { 'emails' => { 'label' => 'Письма в день', 'from' => 'как в тарифе (100 писем в день)', 'to' => 'своё число (50 писем в день)' },
                 'agents' => { 'label' => 'Операторы', 'from' => 'своё число (5 операторов)', 'to' => 'без ограничений' },
                 'storage_bytes' => { 'label' => 'Хранилище', 'from' => 'без ограничений', 'to' => 'своё число (0,5 ГБ)' } }
      lines = entry('update_limits', 'limits' => limits).limit_lines

      expect(lines).to eq(['Операторы: своё число (5 операторов) → без ограничений',
                           'Хранилище: без ограничений → своё число (0,5 ГБ)',
                           'Письма в день: как в тарифе (100 писем в день) → своё число (50 писем в день)'])
    end

    it 'takes the name of a limit from the screens when the entry has none' do
      lines = entry('update_limits', 'limits' => { 'agents' => { 'from' => 'a', 'to' => 'b' } }).limit_lines

      expect(lines).to eq(['Операторы: a → b'])
    end

    it 'tells the limits a plan wrote in words, from the numbers' do
      changes = { 'limits' => { 'conversations' => { 'from' => nil, 'to' => 5 }, 'agents' => { 'from' => 1, 'to' => nil } } }

      expect(entry('apply_plan', changes).limit_lines).to eq(['Операторы: 1 → общее значение', 'Диалоги за 30 дней: не задан → 5'])
    end

    it 'has no lines for the entries that do not change limits that way', :aggregate_failures do
      expect(entry('update', 'limits' => [{ 'agents' => 1 }, { 'agents' => 2 }]).limit_lines).to be_empty
      expect(entry('update_limits', 'name' => 'x').limit_lines).to be_empty
      expect(entry('apply_plan', 'limits' => {}).limit_lines).to be_empty
      expect(entry('update_limits', nil).limit_lines).to be_empty
    end
  end

  describe '#rest' do
    it 'is the entry without the limits that are told in lines' do
      changes = { 'before' => { 'plan' => nil }, 'limits' => { 'agents' => { 'from' => 0, 'to' => 5 } } }

      expect(entry('apply_plan', changes).rest).to eq('before' => { 'plan' => nil })
    end

    it 'is empty for an entry that holds nothing but the limits' do
      expect(entry('update_limits', 'limits' => { 'agents' => { 'from' => 'a', 'to' => 'b' } }).rest).to eq({})
    end

    it 'keeps what cannot be told in a line' do
      changes = { 'limits' => { 'agents' => { 'from' => 'a', 'to' => 'b' }, 'strange' => 7 } }

      expect(entry('update_limits', changes).rest).to eq('limits' => { 'strange' => 7 })
    end

    it 'is the whole entry when there are no lines' do
      expect(entry('update', 'name' => %w[A B]).rest).to eq('name' => %w[A B])
    end
  end
end
