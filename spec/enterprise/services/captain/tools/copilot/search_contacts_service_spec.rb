require 'rails_helper'

RSpec.describe Captain::Tools::Copilot::SearchContactsService do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:service) { described_class.new(assistant, user: user) }

  describe '#name' do
    it 'returns the correct service name' do
      expect(service.name).to eq('search_contacts')
    end
  end

  describe '#description' do
    it 'returns the service description' do
      expect(service.description).to eq('Search contacts by name, email, or phone number')
    end
  end

  describe '#parameters' do
    it 'defines email, phone_number, name, and limit parameters' do
      expect(service.parameters.keys).to contain_exactly(:email, :phone_number, :name, :limit)
    end
  end

  describe '#active?' do
    context 'when user has contact_manage permission' do
      let(:custom_role) { create(:custom_role, account: account, permissions: ['contact_manage']) }

      before do
        account_user = AccountUser.find_by(user: user, account: account)
        account_user.update(role: :agent, custom_role: custom_role)
      end

      it 'returns true' do
        expect(service.active?).to be true
      end
    end

    context 'when user does not have contact_manage permission' do
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
    let!(:contact1) { create(:contact, account: account, email: 'test1@example.com', name: 'Test Contact 1', phone_number: '+1234567890') }
    let!(:contact2) { create(:contact, account: account, email: 'test2@example.com', name: 'Test Contact 2', phone_number: '+1234567891') }

    it 'returns a normalized payload filtered by email' do
      payload = JSON.parse(service.execute(email: 'test1@example.com'))

      expect(payload['total_count']).to eq(1)
      expect(payload['filters']).to include('email' => 'test1@example.com')
      expect(payload['contacts'].map { |contact| contact['id'] }).to eq([contact1.id])
    end

    it 'returns a normalized payload filtered by name with limit' do
      payload = JSON.parse(service.execute(name: 'Contact', limit: 1))

      expect(payload['total_count']).to eq(2)
      expect(payload['contacts'].length).to eq(1)
      expect(payload['contacts'].first).to include(
        'id' => contact1.id,
        'name' => 'Test Contact 1',
        'email' => 'test1@example.com'
      )
    end
  end
end
