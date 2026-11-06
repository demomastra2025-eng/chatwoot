require 'rails_helper'

RSpec.describe Captain::Tools::Account::SearchContactsService do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:service) { described_class.new(assistant, user: user) }

  after { Current.reset }

  describe '#name' do
    it 'returns the correct service name' do
      expect(service.name).to eq('search_contacts')
    end
  end

  describe '#description' do
    it 'returns the service description' do
      expect(service.description).to include('full name in Cyrillic or Latin', 'A phone number is not required', 'several contacts match')
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

    it 'finds structured Cyrillic names, surnames, middle names and е/ё with every word required' do
      contact = create(:contact, account: account, name: 'Семён', last_name: 'Киселёв', middle_name: 'Андреевич')

      ['Киселев', 'Андреевич', 'киселев семен', 'Андреевич Киселёв Семён'].each do |query|
        payload = JSON.parse(service.execute(name: query))
        expect(payload['contacts'].pluck('id')).to eq([contact.id]), query
      end
      expect(JSON.parse(service.execute(name: 'Семен Неизвестный'))['total_count']).to eq(0)
    end

    it 'returns every Cyrillic/Latin collision, full name parts and total count before the limit' do
      create(:contact, account: account, name: 'Almas', last_name: 'Orazov', middle_name: 'Nurlanuly')
      create(:contact, account: account, name: 'Алмас', last_name: 'Оразов', middle_name: 'Нұрланұлы')
      create(:contact, account: create(:account), name: 'Almas')

      ['ALMAS', 'Алмас', 'alm', 'алм', 'Оразов Nurlanuly Almas'].each do |query|
        payload = JSON.parse(service.execute(name: query, limit: 1))
        expect(payload['total_count']).to eq(2), query
        expect(payload['contacts'].size).to eq(1)
        expect(payload['contacts'].first).to include('name' => 'Almas', 'last_name' => 'Orazov', 'middle_name' => 'Nurlanuly',
                                                     'display_full_name' => 'Almas Orazov Nurlanuly')
      end
    end

    it 'intersects name candidates with exact email and normalized phone filters' do
      contact = create(:contact, account: account, name: 'Almas', email: 'almas@example.test', phone_number: '+77015550123')
      create(:contact, account: account, name: 'Алмас', email: 'other@example.test', phone_number: '+77015550124')

      payload = JSON.parse(service.execute(name: 'Алмас', email: contact.email, phone_number: '8 (701) 555-01-23'))
      expect(payload['contacts'].pluck('id')).to eq([contact.id])
      expect(JSON.parse(service.execute(name: 'Алмас', email: contact.email.upcase))['total_count']).to eq(0)
      expect(JSON.parse(service.execute(name: 'Алмас', phone_number: '+77015550125'))['total_count']).to eq(0)
    end

    it 'never uses a name filter to search an email, identifier or phone and keeps the IIN sanitizer' do
      contact = create(:contact, account: account, name: 'Almas', identifier: '940720300129')
      create(:contact, account: account, name: 'Other', email: 'almas@example.test', identifier: 'Almas-external')

      payload = JSON.parse(service.execute(name: 'Алмас'))
      expect(payload['contacts'].pluck('id')).to eq([contact.id])
      expect(payload['contacts'].first['identifier']).to be_nil
      expect(JSON.parse(service.execute(name: '940720300129'))['total_count']).to eq(0)
      expect(JSON.parse(service.execute(name: contact1.phone_number))['total_count']).to eq(0)
    end

    it 'keeps patient search restricted to the conversation contact even when another spelling matches' do
      caller = create(:contact, account: account, name: 'Алмас')
      conversation = create(:conversation, account: account, contact: caller)
      create(:contact, account: account, name: 'Almas')
      service.patient_scope = Captain::Tools::Agent::PatientScope.new(assistant: assistant, conversation: conversation)

      payload = JSON.parse(service.execute(name: 'Almas'))
      expect(payload['total_count']).to eq(1)
      expect(payload['contacts'].pluck('id')).to eq([caller.id])
      expect(JSON.parse(service.execute(name: contact1.name))['total_count']).to eq(0)
    end

    it 'treats wildcard characters literally and cleans pasted names before matching' do
      contact = create(:contact, account: account, name: 'Алмас (VIP) [1] %_\\')

      expect(JSON.parse(service.execute(name: "\u200EAlmas\u0000"))['contacts'].pluck('id')).to eq([contact.id])
      expect(JSON.parse(service.execute(name: 'Almas (VIP) [1] %_\\'))['contacts'].pluck('id')).to eq([contact.id])
      expect(JSON.parse(service.execute(name: 'Almas.*'))['total_count']).to eq(0)
      expect(JSON.parse(service.execute(name: 'Contact%'))['total_count']).to eq(0)
      expect(JSON.parse(service.execute(name: 'Contact_'))['total_count']).to eq(0)
    end
  end
end
