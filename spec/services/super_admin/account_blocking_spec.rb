require 'rails_helper'

RSpec.describe SuperAdmin::AccountBlocking do
  let(:actor) { create(:super_admin, name: 'Айдар Админ') }
  let(:account) { create(:account) }
  let(:blocking) { described_class.new(account: account, actor: actor) }

  def audits(action) = Audited::Audit.where(auditable_type: 'Account', auditable_id: account.id, action: action)

  describe '#suspend' do
    it 'blocks the account and says so' do
      expect(blocking.suspend(reason: 'non_payment', note: 'счёт')).to eq(:suspended)

      expect(account.reload).to be_suspended
    end

    it 'writes one entry with the move, the reason and the comment' do
      blocking.suspend(reason: 'client_request', note: ' по просьбе   клиента ')

      expect(audits('suspend_account').count).to eq(1)
      audit = audits('suspend_account').last
      expect(audit).to have_attributes(associated_id: account.id, user_id: actor.id, comment: 'super_admin')
      expect(audit.audited_changes).to eq('status' => %w[active suspended], 'reason' => 'client_request', 'note' => 'по просьбе клиента')
    end

    it 'blocks once: an account that is blocked already is left as it is and nothing is written' do
      account.update!(status: :suspended)

      expect(blocking.suspend(reason: 'other')).to eq(:already_suspended)
      expect(audits('suspend_account')).to be_empty
    end

    it 'writes the entry of the audit log after the lock is let go, so a problem of the log cannot undo the block' do
      level = nil
      base = ActiveRecord::Base.connection.open_transactions
      allow(SuperAdmin::AccountAudit).to receive(:record) { level = ActiveRecord::Base.connection.open_transactions }

      expect(blocking.suspend(reason: 'other')).to eq(:suspended)

      expect(level).to eq(base)
      expect(account.reload).to be_suspended
    end

    it 'keeps only the reasons of the list, and drops an empty comment' do
      blocking.suspend(reason: 'whatever', note: '   ')

      expect(audits('suspend_account').last.audited_changes).to eq('status' => %w[active suspended])
    end

    it 'writes nothing and does not block when the account cannot be saved' do
      allow(account).to receive(:update!).and_raise(ActiveRecord::RecordInvalid)

      expect { blocking.suspend(reason: 'other') }.to raise_error(ActiveRecord::RecordInvalid)

      expect(account.reload).to be_active
      expect(audits('suspend_account')).to be_empty
    end
  end

  describe '#activate' do
    before { account.update!(status: :suspended) }

    it 'unblocks the account and writes the move' do
      expect(blocking.activate).to eq(:activated)

      expect(account.reload).to be_active
      expect(audits('activate_account').last.audited_changes).to eq('status' => %w[suspended active])
    end

    it 'writes its entry after the lock as well' do
      level = nil
      base = ActiveRecord::Base.connection.open_transactions
      allow(SuperAdmin::AccountAudit).to receive(:record) { level = ActiveRecord::Base.connection.open_transactions }

      blocking.activate

      expect(level).to eq(base)
      expect(account.reload).to be_active
    end

    it 'does nothing for an account that works' do
      account.update!(status: :active)

      expect(blocking.activate).to eq(:already_active)
      expect(audits('activate_account')).to be_empty
    end
  end

  describe '.last_block' do
    it 'is nothing for an account that works' do
      blocking.suspend(reason: 'other')
      blocking.activate

      expect(described_class.last_block(account.reload)).to be_nil
    end

    it 'is nothing for an account blocked by hand that no entry explains' do
      account.update!(status: :suspended)

      expect(described_class.last_block(account)).to be_nil
    end

    it 'says when, by whom, why and with what comment the account was blocked' do
      blocking.suspend(reason: 'non_payment', note: 'счёт за октябрь')

      block = described_class.last_block(account.reload)

      expect(block).to have_attributes(by: 'Айдар Админ', reason: 'non_payment', note: 'счёт за октябрь')
      expect(block.at).to be_within(5.seconds).of(Time.current)
    end

    it 'reads the newest block when the account was blocked, unblocked and blocked again' do
      blocking.suspend(reason: 'non_payment')
      blocking.activate
      blocking.suspend(reason: 'client_request')

      expect(described_class.last_block(account.reload).reason).to eq('client_request')
    end

    it 'reads a block made on the list with many accounts, which has no reason' do
      SuperAdmin::BulkAccounts.new(action: 'suspend', ids: [account.id], actor: actor).apply

      block = described_class.last_block(account.reload)

      expect(block).to be_present
      expect(block).to have_attributes(reason: nil, note: nil, by: 'Айдар Админ')
    end
  end
end
