require 'rails_helper'

RSpec.describe Companies::ContactMembershipService, type: :service do
  let(:account) { create(:account) }
  let(:company) { create(:company, account: account) }
  let(:service) { described_class.new(company: company) }

  describe '#assign' do
    it 'assigns the contact through normal company membership and records activity' do
      contact = create(:contact, account: account, company_id: nil, last_activity_at: 4.hours.ago)

      expect do
        service.assign(contact: contact)
      end.to change { company.reload.contacts_count.to_i }.by(1)

      expect(contact.reload.company).to eq(company)
      expect(company.last_activity_at.to_i).to eq(contact.last_activity_at.to_i)
    end

    it 'rejects contacts from another account' do
      other_contact = create(:contact, account: create(:account), company_id: nil)

      expect do
        service.assign(contact: other_contact)
      end.to raise_error(ActiveRecord::RecordNotFound)
    end
  end

  describe '#remove' do
    it 'removes direct company membership' do
      contact = create(:contact, account: account, company: company)

      expect do
        service.remove(contact: contact)
      end.to change { company.reload.contacts_count }.by(-1)

      expect(contact.reload.company_id).to be_nil
    end

    it 'rejects contacts from another account' do
      other_contact = create(:contact, account: create(:account), company_id: nil)

      expect do
        service.remove(contact: other_contact)
      end.to raise_error(ActiveRecord::RecordNotFound)
    end
  end
end
