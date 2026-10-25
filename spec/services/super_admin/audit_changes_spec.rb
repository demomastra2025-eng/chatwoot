# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SuperAdmin::AuditChanges do
  # the words of SuperAdmin::DisplayHelper#super_admin_limit_value, short
  let(:limit_value) do
    lambda do |_key, value, given_back: false|
      next value.to_s unless value.nil?

      given_back ? 'общее значение' : 'не задан'
    end
  end

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

  # An entry of an inbox written before the secrets of the channels were filtered at write time (AuditLogs::SecretFilter)
  describe 'the secrets of a channel' do
    def inbox_entry(changes)
      described_class.new(Audited::Audit.new(auditable_type: 'Inbox', action: 'update', audited_changes: changes), limit_value)
    end

    it 'never shows a stored session string or API key, and keeps the rest of the entry', :aggregate_failures do
      changes = inbox_entry(
        'string_session' => [nil, 'stored-telethon-session'],
        'provider_config' => [{}, { 'api_key' => 'stored-api-key', 'phone_number_id' => '7' }],
        'name' => %w[A B]
      )

      expect(changes.rest).to eq(
        'string_session' => [nil, '[FILTERED]'],
        'provider_config' => [{}, { 'api_key' => '[FILTERED]', 'phone_number_id' => '7' }],
        'name' => %w[A B]
      )
      expect(changes.readable.to_json).not_to include('stored-telethon-session', 'stored-api-key')
    end

    it 'filters an entry kept as a JSON string' do
      changes = inbox_entry({ 'api_hash' => %w[stored-old-hash stored-new-hash] }.to_json)

      expect(changes.rest).to eq('api_hash' => ['[FILTERED]', '[FILTERED]'])
    end
  end
end
