require 'rails_helper'

RSpec.describe Captain::Tools::Copilot::CreateContactService do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:service) { described_class.new(assistant, user: user) }

  describe '#active?' do
    it 'requires contact management permission' do
      custom_role = create(:custom_role, account: account, permissions: [])
      AccountUser.find_by!(user: user, account: account).update!(role: :agent, custom_role: custom_role)

      expect(service.active?).to be false
    end
  end

  describe '#execute' do
    it 'creates an account-scoped contact with structured output' do
      payload = JSON.parse(
        service.execute(
          name: 'Aruzhan K',
          email: 'aruzhan@example.com',
          phone_number: '+77001234567',
          identifier: 'lead-001',
          custom_attributes: { 'source' => 'captain', 'vip' => true }
        )
      )
      contact = account.contacts.find(payload.fetch('contact').fetch('id'))

      expect(payload).to include('action' => 'create_contact', 'status' => 'created')
      expect(payload.fetch('contact')).to include(
        'id' => contact.id,
        'name' => 'Aruzhan K',
        'email' => 'aruzhan@example.com',
        'phone_number' => '+77001234567',
        'identifier' => 'lead-001',
        'custom_attributes' => include('source' => 'captain', 'vip' => true)
      )
      expect(contact.account_id).to eq(account.id)
    end

    it 'does not create duplicate contacts when called twice with the same arguments' do
      first_payload = JSON.parse(service.execute(name: 'Repeat Lead', email: 'repeat@example.com'))
      second_payload = JSON.parse(service.execute(name: 'Repeat Lead', email: 'repeat@example.com'))

      expect(first_payload.fetch('contact').fetch('id')).to eq(second_payload.fetch('contact').fetch('id'))
      expect(account.contacts.where(email: 'repeat@example.com').count).to eq(1)
    end

    it 'rejects contacts without any identifying fields' do
      result = service.execute(name: 'Only Name')

      expect(result).to include('At least one of email, phone_number, or identifier is required')
      expect(account.contacts.where(name: 'Only Name')).to be_empty
    end
  end
end
