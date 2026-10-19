# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SuperAdmin::OrganizationLinks do
  subject(:links) { described_class.new(actor: super_admin) }

  let(:super_admin) { create(:super_admin) }
  let(:first) { create(:organization, name: 'Первая') }
  let(:second) { create(:organization, name: 'Вторая') }
  let(:account) { create(:account, name: 'Филиал') }

  def audits(record, action)
    Audited::Audit.where(auditable_type: record.class.name, auditable_id: record.id, action: action)
  end

  describe '#link' do
    it 'links an account without an organization and records both sides' do
      expect(links.link(account: account, organization: first)).to be_changed

      expect(account.reload.organization).to eq(first)
      expect(audits(account, 'link_organization').sole.audited_changes).to eq('organization_id' => [nil, first.id],
                                                                              'organization_name' => [nil, 'Первая'])
      expect(audits(first, 'link_account').sole.audited_changes).to eq('account_id' => account.id, 'account_name' => 'Филиал')
      expect(audits(first, 'unlink_account')).to be_empty
    end

    it 'moves an account from one organization to another and records the organization it left as well' do
      links.link(account: account, organization: first)

      expect(links.link(account: account, organization: second)).to have_attributes(changed?: true, previous: first)

      expect(account.reload.organization).to eq(second)
      expect(audits(account, 'link_organization').order(:id).last.audited_changes)
        .to eq('organization_id' => [first.id, second.id], 'organization_name' => %w[Первая Вторая])
      expect(audits(first, 'unlink_account').sole.audited_changes).to include('account_id' => account.id)
      expect(audits(second, 'link_account').sole.audited_changes).to include('account_id' => account.id)
    end

    it 'does nothing and records nothing when the account is already there' do
      links.link(account: account, organization: first)
      Audited::Audit.delete_all

      expect(links.link(account: account, organization: first)).not_to be_changed

      expect(Audited::Audit.count).to eq(0)
    end

    it 'signs the entries with the actor, or as the system without one' do
      links.link(account: account, organization: first)
      described_class.new.link(account: create(:account), organization: first)

      comments = Audited::Audit.where(action: 'link_organization').order(:id).pluck(:comment)
      expect(comments).to eq(%w[super_admin system])
      expect(audits(account, 'link_organization').sole.user).to eq(super_admin)
    end
  end

  describe '#unlink' do
    it 'unlinks the account and records both sides' do
      links.link(account: account, organization: first)

      expect(links.unlink(account: account)).to have_attributes(changed?: true, previous: first)

      expect(account.reload.organization).to be_nil
      expect(audits(account, 'unlink_organization').sole.audited_changes).to eq('organization_id' => [first.id, nil],
                                                                                'organization_name' => ['Первая', nil])
      expect(audits(first, 'unlink_account').sole.audited_changes).to include('account_id' => account.id)
    end

    it 'does nothing and records nothing for an account without an organization' do
      expect(links.unlink(account: account)).not_to be_changed

      expect(Audited::Audit.count).to eq(0)
    end
  end

  # The page a super admin works from was drawn earlier: `stale` is the account as that page saw it, `move_behind_back`
  # is what another super admin did in the meantime.
  describe 'when the account changed hands after the page was drawn' do
    def move_behind_back(account, organization)
      account.update_columns(organization_id: organization&.id) # rubocop:disable Rails/SkipsModelValidations
    end

    let(:stale) { Account.find(account.id) }

    describe '#link from the card of an organization (expected_holder: nil)' do
      it 'links a free account' do
        expect(links.link(account: stale, organization: first, expected_holder: nil)).to be_changed

        expect(account.reload.organization).to eq(first)
      end

      it 'refuses an account that was linked elsewhere in the meantime, changes nothing and records nothing' do
        stale
        move_behind_back(account, second)

        expect { links.link(account: stale, organization: first, expected_holder: nil) }
          .to raise_error(described_class::Refused) { |error| expect(error.holder).to eq(second) }

        expect(account.reload.organization).to eq(second)
        expect(Audited::Audit.count).to eq(0)
      end

      it 'is not a refusal when the account was linked to this very organization in the meantime' do
        stale
        move_behind_back(account, first)

        expect(links.link(account: stale, organization: first, expected_holder: nil)).not_to be_changed

        expect(Audited::Audit.count).to eq(0)
      end
    end

    describe '#unlink from the card of an organization (expected_holder: organization)' do
      before { move_behind_back(account, first) }

      it 'unlinks an account that is still linked to that organization' do
        expect(links.unlink(account: stale, expected_holder: first)).to have_attributes(changed?: true, previous: first)

        expect(account.reload.organization).to be_nil
      end

      it 'refuses an account that was moved to another organization in the meantime' do
        stale
        move_behind_back(account, second)

        expect { links.unlink(account: stale, expected_holder: first) }
          .to raise_error(described_class::Refused) { |error| expect(error.holder).to eq(second) }

        expect(account.reload.organization).to eq(second)
        expect(Audited::Audit.count).to eq(0)
      end

      it 'refuses an account that was unlinked in the meantime' do
        stale
        move_behind_back(account, nil)

        expect { links.unlink(account: stale, expected_holder: first) }
          .to raise_error(described_class::Refused) { |error| expect(error.holder).to be_nil }

        expect(Audited::Audit.count).to eq(0)
      end
    end

    describe 'the card and the edit form of the account (no expected holder)' do
      it 'moves the account from wherever it is now and records what it really left' do
        move_behind_back(account, first)
        stale
        move_behind_back(account, second)
        third = create(:organization, name: 'Третья')

        result = links.link(account: stale, organization: third)

        expect(result).to have_attributes(changed?: true, previous: second)
        expect(account.reload.organization).to eq(third)
        expect(audits(account, 'link_organization').sole.audited_changes)
          .to eq('organization_id' => [second.id, third.id], 'organization_name' => %w[Вторая Третья])
        expect(audits(second, 'unlink_account').count).to eq(1)
        expect(audits(first, 'unlink_account')).to be_empty
      end

      it 'unlinks from wherever the account is now' do
        stale
        move_behind_back(account, second)

        expect(links.unlink(account: stale)).to have_attributes(changed?: true, previous: second)

        expect(audits(second, 'unlink_account').count).to eq(1)
      end
    end
  end

  describe 'the lock' do
    def statements(&)
      sql = []
      subscriber = ->(*, payload) { sql << payload[:sql] }
      ActiveSupport::Notifications.subscribed(subscriber, 'sql.active_record', &)
      sql
    end

    it 'reads the account FOR UPDATE and writes inside the same transaction, before the audit entries' do
      sql = statements { links.link(account: account, organization: first) }

      lock = sql.index { |statement| statement.include?('FOR UPDATE') && statement.include?('"accounts"') }
      write = sql.index { |statement| statement.start_with?('UPDATE "accounts" SET "organization_id"') }
      audit = sql.index { |statement| statement.start_with?('INSERT INTO "audits"') }
      expect(lock).to be < write
      expect(write).to be < audit
    end

    it 'locks the account on unlinking as well' do
      links.link(account: account, organization: first)

      sql = statements { links.unlink(account: account) }

      expect(sql.grep(/FOR UPDATE/).grep(/"accounts"/)).not_to be_empty
    end
  end
end
