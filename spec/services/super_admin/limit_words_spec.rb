# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SuperAdmin::LimitWords do
  let(:max) { ChatwootApp.max_limit }

  describe '.amount' do
    it 'says a count with the right Russian form of the noun', :aggregate_failures do
      expect(described_class.amount('agents', 1)).to eq('1 оператор')
      expect(described_class.amount('agents', 3)).to eq('3 оператора')
      expect(described_class.amount('agents', 5)).to eq('5 операторов')
      expect(described_class.amount('agents', 11)).to eq('11 операторов')
      expect(described_class.amount('agents', 22)).to eq('22 оператора')
      expect(described_class.amount('conversations', 1500)).to eq('1 500 диалогов')
      expect(described_class.amount('non_web_inboxes', 2)).to eq('2 основных канала')
      expect(described_class.amount('captain_documents', 21)).to eq('21 документ ИИ')
      expect(described_class.amount('emails', 100)).to eq('100 писем в день')
    end

    it 'has the words of every limit' do
      Accounts::Plans::LIMIT_KEYS.each do |key|
        expect(described_class.amount(key, 7)).to match(/\p{Cyrillic}/), "no words for #{key}"
      end
    end

    it 'says the storage in ГБ' do
      expect(described_class.amount('storage_bytes', 50.gigabytes)).to eq('50 ГБ')
      expect(described_class.amount('storage_bytes', 1.5.gigabytes)).to eq('1,5 ГБ')
    end

    it 'says the storage with the decimals of the field it is typed in, never a rounder size than the field shows' do
      expect(described_class.amount('storage_bytes', 5_000_000_000)).to eq('4,66 ГБ')
      expect(described_class.amount('storage_bytes', 5_003_636_900)).to eq('4,66 ГБ')
      expect(described_class.amount('storage_bytes', (BigDecimal('4.7') * 1.gigabyte).round(0).to_i)).to eq('4,7 ГБ')
      expect(described_class.amount('storage_bytes', 1024.gigabytes)).to eq('1 024 ГБ')
      expect(described_class.amount('storage_bytes', 512.megabytes)).to eq('512 МБ')
    end

    it 'says no limit for nothing and for the number that stands for no limit, never the number' do
      expect(described_class.amount('agents', nil)).to eq('без ограничений')
      expect(described_class.amount('agents', max)).to eq('без ограничений')
      expect(described_class.amount('storage_bytes', max * 1.gigabyte)).to eq('без ограничений')
      expect(described_class.amount('captain_tokens', max * 1_000_000)).to eq('без ограничений')
    end

    it 'says 0 as it is' do
      expect(described_class.amount('inboxes', 0)).to eq('0 каналов')
    end
  end

  describe '.position and .audit_changes' do
    let(:position) { Accounts::LimitSettings::Position }

    it 'says where a limit comes from' do
      expect(described_class.position('agents', position.new(source: :plan, value: nil))).to eq('как в тарифе (без ограничений)')
      expect(described_class.position('agents', position.new(source: :plan, value: 5))).to eq('как в тарифе (5 операторов)')
      expect(described_class.position('agents', position.new(source: :unlimited, value: max))).to eq('без ограничений')
      expect(described_class.position('storage_bytes', position.new(source: :custom, value: 2.gigabytes))).to eq('своё число (2 ГБ)')
    end

    it 'leaves out a change the words cannot tell apart' do
      changes = { 'agents' => { 'from' => position.new(source: :custom, value: 3), 'to' => position.new(source: :custom, value: 3) },
                  'storage_bytes' => { 'from' => position.new(source: :custom, value: 5_000_000_000),
                                       'to' => position.new(source: :custom, value: 5_003_636_900) },
                  'emails' => { 'from' => position.new(source: :plan, value: nil), 'to' => position.new(source: :custom, value: 5) } }

      expect(described_class.audit_changes(changes).keys).to eq(['emails'])
    end

    it 'puts the changes of a save into words' do
      changes = { 'agents' => { 'from' => position.new(source: :plan, value: nil), 'to' => position.new(source: :custom, value: 3) } }

      expect(described_class.audit_changes(changes)).to eq(
        'agents' => { 'label' => 'Операторы', 'from' => 'как в тарифе (без ограничений)', 'to' => 'своё число (3 оператора)' }
      )
    end
  end
end
