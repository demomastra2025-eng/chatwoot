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

  describe 'contact owner sync' do
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
  end
end
