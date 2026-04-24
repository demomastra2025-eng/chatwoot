require 'rails_helper'

RSpec.describe Captain::Tools::Copilot::GetContactService do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:service) { described_class.new(assistant, user: user) }

  describe '#name' do
    it 'returns the correct service name' do
      expect(service.name).to eq('get_contact')
    end
  end

  describe '#active?' do
    context 'when user is an admin' do
      let(:user) { create(:user, :administrator, account: account) }

      it 'returns true' do
        expect(service.active?).to be true
      end
    end

    context 'when user has custom role without contact_manage permission' do
      let(:custom_role) { create(:custom_role, account: account, permissions: []) }

      before do
        account_user = AccountUser.find_by(user: user, account: account)
        account_user.update(role: :agent, custom_role: custom_role)
      end

      it 'returns false' do
        expect(service.active?).to be false
      end
    end
  end

  describe '#execute' do
    it 'returns not found message when contact is missing' do
      expect(service.execute(contact_id: 999)).to eq('Contact not found')
    end

    it 'returns a normalized contact payload' do
      company = create(:company, account: account, name: 'OneLink')
      contact = create(
        :contact,
        account: account,
        company: company,
        name: 'Aruzhan',
        email: 'aruzhan@example.com',
        phone_number: '+77001234567',
        identifier: 'IIN-123',
        custom_attributes: { 'vip' => true }
      )

      payload = JSON.parse(service.execute(contact_id: contact.id))

      expect(payload['contact']).to include(
        'id' => contact.id,
        'name' => 'Aruzhan',
        'email' => 'aruzhan@example.com',
        'phone_number' => '+77001234567',
        'identifier' => 'IIN-123',
        'company_id' => company.id,
        'company_name' => 'OneLink',
        'custom_attributes' => { 'vip' => true }
      )
    end
  end
end
