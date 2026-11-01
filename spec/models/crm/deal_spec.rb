require 'rails_helper'

RSpec.describe Crm::Deal do
  let(:account) { create(:account) }
  let(:pipeline) { create(:crm_pipeline, account: account) }
  let(:stage) { create(:crm_stage, account: account, pipeline: pipeline) }
  let(:owner) { create(:user, account: account, role: :agent) }
  let(:new_owner) { create(:user, account: account, role: :agent) }

  describe 'associations' do
    it { is_expected.to belong_to(:owner).optional }
    it { is_expected.to have_many(:contacts).through(:deal_contacts) }
  end

  describe 'historical creator membership' do
    let(:creator) { create(:user, account: account, role: :agent) }
    let(:deal) { create(:crm_deal, account: account, pipeline: pipeline, stage: stage, creator: creator) }
    let(:foreign_creator) { create(:user, account: create(:account), role: :agent) }

    def revoke_creator_membership
      deal
      AccountUser.where(account: account, user: creator).delete_all
      expect(account.users.exists?(id: creator.id)).to be(false)
      deal.reload
    end

    it 'leases a due deal without erasing its creator after membership was revoked' do
      revoke_creator_membership

      expect { deal.update!(appointment_automation_next_check_at: 5.minutes.from_now) }.not_to raise_error

      expect(deal.reload.creator_id).to eq(creator.id)
      expect(deal.appointment_automation_next_check_at).to be > Time.current
    end

    it 'allows an unrelated update while retaining historical authorship' do
      revoke_creator_membership

      deal.update!(description: 'Updated after membership revocation')

      expect(deal.reload.creator_id).to eq(creator.id)
      expect(deal.description).to eq('Updated after membership revocation')
    end

    it 'rejects a foreign creator on a new deal' do
      new_deal = build(:crm_deal, account: account, pipeline: pipeline, stage: stage, creator: foreign_creator)

      expect(new_deal).not_to be_valid
      expect(new_deal.errors[:creator]).to include('must belong to the current account')
    end

    it 'rejects creator reassignment outside the account' do
      revoke_creator_membership
      deal.creator = foreign_creator

      expect(deal).not_to be_valid
      expect(deal.errors[:creator]).to include('must belong to the current account')
      expect(deal.reload.creator_id).to eq(creator.id)
    end

    it 'permits explicit reassignment to a current account member' do
      revoke_creator_membership
      replacement = create(:user, account: account, role: :agent)

      deal.update!(creator: replacement)

      expect(deal.reload.creator_id).to eq(replacement.id)
    end

    it 'revalidates an unchanged creator when the deal account changes' do
      deal
      destination = create(:account)
      destination_pipeline = create(:crm_pipeline, account: destination)
      destination_stage = create(:crm_stage, account: destination, pipeline: destination_pipeline)
      deal.assign_attributes(account: destination, pipeline: destination_pipeline, stage: destination_stage)

      expect(deal).not_to be_valid
      expect(deal.errors[:creator]).to include('must belong to the current account')
      expect(deal.reload.account_id).to eq(account.id)
    end

    it 'continues checking the owner on unrelated updates' do
      revoke_creator_membership
      deal.owner = foreign_creator

      expect(deal).not_to be_valid
      expect(deal.errors[:owner]).to include('must belong to the current account')
      expect(deal.errors[:creator]).to be_empty
    end

    it 'continues checking the team on unrelated updates' do
      revoke_creator_membership
      deal.team = create(:team, account: foreign_creator.accounts.first)

      expect(deal).not_to be_valid
      expect(deal.errors[:team]).to include('must belong to the current account')
      expect(deal.errors[:creator]).to be_empty
    end
  end

  describe 'contact owner sync' do
    before { new_owner }

    def deal_with_primary_contact(contact_owner: owner, deal_owner: owner, **contact_attributes)
      contact = create(:contact, account: account, owner: contact_owner, **contact_attributes)
      deal = create(:crm_deal, account: account, pipeline: pipeline, stage: stage, owner: deal_owner)
      create(:crm_deal_contact, account: account, deal: deal, contact: contact, primary: true)
      [deal, contact]
    end

    it 'syncs owner changes to the primary contact' do
      contact = create(:contact, account: account, owner: owner)
      deal = create(:crm_deal, account: account, pipeline: pipeline, stage: stage, owner: owner)
      create(:crm_deal_contact, account: account, deal: deal, contact: contact, primary: true)

      deal.update!(owner: new_owner)

      expect(contact.reload.owner).to eq(new_owner)
    end

    it 'does not sync owner changes to non-primary contacts' do
      contact = create(:contact, account: account, owner: owner)
      deal = create(:crm_deal, account: account, pipeline: pipeline, stage: stage, owner: owner)
      create(:crm_deal_contact, account: account, deal: deal, contact: contact, primary: false)

      deal.update!(owner: new_owner)

      expect(contact.reload.owner).to eq(owner)
    end

    it 'overwrites an owner that was set on the contact by hand' do
      deal, contact = deal_with_primary_contact
      contact.update!(owner: nil)
      deal.reload

      deal.update!(owner: new_owner)

      expect(contact.reload.owner).to eq(new_owner)
    end

    it 'leaves the primary contact without owner when the deal is released' do
      deal, contact = deal_with_primary_contact

      deal.update!(owner: nil)

      expect(contact.reload.owner).to be_nil
    end

    it 'does nothing without a primary contact' do
      deal = create(:crm_deal, account: account, pipeline: pipeline, stage: stage, owner: owner)

      expect { deal.update!(owner: new_owner) }.not_to raise_error
      expect(deal.reload.owner).to eq(new_owner)
    end

    it 'does nothing while the owner stays the same' do
      deal, contact = deal_with_primary_contact
      allow(Crm::Deals::ContactOwnerSync).to receive(:call).and_call_original

      deal.update!(title: 'Renamed deal')

      expect(Crm::Deals::ContactOwnerSync).not_to have_received(:call)
      expect(contact.reload.owner).to eq(owner)
    end

    it 'follows the owner change even when the deal is saved and reloaded again in the same transaction' do
      deal, contact = deal_with_primary_contact

      described_class.transaction do
        deal.update!(owner: new_owner)
        deal.update!(title: 'Renamed in the same transaction')
        deal.reload
      end

      expect(contact.reload.owner).to eq(new_owner)
    end

    it 'does not hand over anything when the owner change is rolled back' do
      deal, contact = deal_with_primary_contact

      described_class.transaction do
        deal.update!(owner: new_owner)
        raise ActiveRecord::Rollback
      end
      deal.reload.update!(title: 'Renamed after the rollback')

      expect(contact.reload.owner).to eq(owner)
    end

    it 'does not fail when the deal is deleted right after its owner changed' do
      deal, contact = deal_with_primary_contact
      Crm::DealContact.where(deal_id: deal.id).delete_all

      expect do
        described_class.transaction do
          deal.update!(owner: new_owner)
          deal.destroy!
        end
      end.not_to raise_error
      expect(contact.reload.owner).to eq(owner)
    end

    it 'settles after one hop when the contact owner sync moves the other deals of the client' do
      deal, contact = deal_with_primary_contact
      other_deal = create(:crm_deal, account: account, pipeline: pipeline, stage: stage, owner: owner)
      create(:crm_deal_contact, account: account, deal: other_deal, contact: contact, primary: true)
      allow(Crm::Deals::ContactOwnerSync).to receive(:call).and_call_original

      deal.update!(owner: new_owner)

      expect(contact.reload.owner).to eq(new_owner)
      expect(other_deal.reload.owner).to eq(new_owner)
      # one call for the deal that was edited and one for the deal the contact sync moved: no further round trips
      expect(Crm::Deals::ContactOwnerSync).to have_received(:call).twice
    end
  end
end
