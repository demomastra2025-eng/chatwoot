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
      expect(links.link(account: account, organization: first)).to be(true)

      expect(account.reload.organization).to eq(first)
      expect(audits(account, 'link_organization').sole.audited_changes).to eq('organization_id' => [nil, first.id],
                                                                              'organization_name' => [nil, 'Первая'])
      expect(audits(first, 'link_account').sole.audited_changes).to eq('account_id' => account.id, 'account_name' => 'Филиал')
      expect(audits(first, 'unlink_account')).to be_empty
    end

    it 'moves an account from one organization to another and records the organization it left as well' do
      links.link(account: account, organization: first)

      expect(links.link(account: account, organization: second)).to be(true)

      expect(account.reload.organization).to eq(second)
      expect(audits(account, 'link_organization').order(:id).last.audited_changes)
        .to eq('organization_id' => [first.id, second.id], 'organization_name' => %w[Первая Вторая])
      expect(audits(first, 'unlink_account').sole.audited_changes).to include('account_id' => account.id)
      expect(audits(second, 'link_account').sole.audited_changes).to include('account_id' => account.id)
    end

    it 'does nothing and records nothing when the account is already there' do
      links.link(account: account, organization: first)
      Audited::Audit.delete_all

      expect(links.link(account: account, organization: first)).to be(false)

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

      expect(links.unlink(account: account)).to be(true)

      expect(account.reload.organization).to be_nil
      expect(audits(account, 'unlink_organization').sole.audited_changes).to eq('organization_id' => [first.id, nil],
                                                                                'organization_name' => ['Первая', nil])
      expect(audits(first, 'unlink_account').sole.audited_changes).to include('account_id' => account.id)
    end

    it 'does nothing and records nothing for an account without an organization' do
      expect(links.unlink(account: account)).to be(false)

      expect(Audited::Audit.count).to eq(0)
    end
  end
end
