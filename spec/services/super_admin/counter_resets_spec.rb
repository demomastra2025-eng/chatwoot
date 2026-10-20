require 'rails_helper'

RSpec.describe SuperAdmin::CounterResets do
  let(:account) { create(:account) }
  let(:resets) { described_class.new(account) }

  describe '#current' do
    it 'reads the number each counter shows now' do
      account.update!(custom_attributes: account.custom_attributes.merge('captain_responses_usage' => 12, 'captain_tokens_usage' => 3400))
      2.times { account.increment_email_sent_count }

      expect(resets.current(:responses)).to eq(12)
      expect(resets.current(:tokens)).to eq(3400)
      expect(resets.current(:emails)).to eq(2)
    end

    it 'is zero for a counter nothing has counted, and never below zero' do
      account.update!(custom_attributes: account.custom_attributes.merge('captain_tokens_usage' => -5))

      expect(resets.current(:responses)).to eq(0)
      expect(resets.current(:tokens)).to eq(0)
    end

    it 'does not know a counter that is not on the list' do
      expect { resets.current(:storage) }.to raise_error(ArgumentError, /unknown counter/)
    end
  end

  describe '.action_for' do
    it 'names the entry of the audit log each reset leaves' do
      expect(described_class::KINDS.keys.map { |kind| described_class.action_for(kind) })
        .to eq(%w[reset_captain_responses_usage reset_captain_tokens_usage reset_email_usage])
    end
  end

  describe '#last' do
    let(:admin) { create(:super_admin, name: 'Айдар Админ') }

    def reset!(kind, by: admin)
      SuperAdmin::AccountAudit.record(account: account, actor: by, action: described_class.action_for(kind), changes: { 'before' => 1, 'after' => 0 })
    end

    it 'is nothing for a counter nobody has reset' do
      expect(resets.last(:responses)).to be_nil
    end

    it 'says when and by whom the counter was last reset, for each counter on its own' do
      reset!(:responses)

      expect(resets.last(:responses)).to have_attributes(by: 'Айдар Админ')
      expect(resets.last(:responses).at).to be_within(5.seconds).of(Time.current)
      expect(resets.last(:tokens)).to be_nil
    end

    it 'reads the newest reset' do
      reset!(:emails, by: create(:super_admin, name: 'Первый'))
      reset!(:emails, by: create(:super_admin, name: 'Второй'))

      expect(resets.last(:emails).by).to eq('Второй')
    end

    it 'finds the last reset of a counter however many times another one was reset since' do
      reset!(:emails, by: create(:super_admin, name: 'Давний'))
      35.times { reset!(:responses) }

      expect(resets.last(:emails)).to have_attributes(by: 'Давний')
      expect(resets.last(:responses)).to have_attributes(by: 'Айдар Админ')
      expect(resets.last(:tokens)).to be_nil
    end

    it 'reads the entries of the three counters with one query' do
      reset!(:emails)
      reset!(:tokens)
      reset!(:responses)
      queries = []
      callback = ->(*, payload) { queries << payload[:sql] if payload[:sql].include?('"audits"') }

      ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') do
        described_class::KINDS.each_key { |kind| resets.last(kind) }
      end

      expect(queries.size).to eq(1)
    end

    it 'does not read the resets of another account' do
      other = create(:account)
      SuperAdmin::AccountAudit.record(account: other, actor: admin, action: described_class.action_for(:responses))

      expect(resets.last(:responses)).to be_nil
    end

    it 'keeps the date when the person who reset it is gone' do
      reset!(:tokens, by: nil)

      expect(resets.last(:tokens)).to have_attributes(by: nil)
      expect(resets.last(:tokens).at).to be_present
    end
  end
end
