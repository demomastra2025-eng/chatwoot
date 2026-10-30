require 'rails_helper'

RSpec.describe Contacts::PhoneLookup do
  let(:account) { create(:account) }
  let!(:person) { create(:contact, account: account, name: 'Данияр', phone_number: '+77012223344') }

  before do
    Contacts::PhoneManagementService.new(account: account, contact: person).add!(
      raw_phone: '+77078889900',
      label: 'Activ 2'
    )
  end

  it 'resolves incoming WhatsApp / channel builder messages from the 2nd personal phone to the same contact' do
    inbox = create(:inbox, account: account)
    contact_inbox = ContactInboxWithContactBuilder.new(
      inbox: inbox,
      source_id: '77078889900',
      contact_attributes: { name: 'Данияр Второй', phone_number: '+77078889900' }
    ).perform

    expect(contact_inbox.contact_id).to eq(person.id)
    expect(account.contacts.count).to eq(1)
  end

  it 'never resolves a shared family phone to the dependent card during channel creation' do
    child = create(:contact, account: account, name: 'Ребёнок', phone_number: nil)
    Contacts::PhoneManagementService.new(account: account, contact: child).add!(
      raw_phone: '+77078889900',
      link_shared: true
    )

    inbox = create(:inbox, account: account)
    contact_inbox = ContactInboxWithContactBuilder.new(
      inbox: inbox,
      source_id: '77078889900',
      contact_attributes: { name: 'Входящий', phone_number: '+77078889900' }
    ).perform

    expect(contact_inbox.contact_id).to eq(person.id)
  end

  it 'finds contacts by 2nd personal phone and shared family phone in Search::ContactQuery across any phone format' do
    child = create(:contact, account: account, name: 'Амина', phone_number: nil)
    Contacts::PhoneManagementService.new(account: account, contact: child).add!(
      raw_phone: '+77012223344',
      link_shared: true
    )

    results_second_phone = Search::ContactQuery.new('8 (707) 888-99-00').apply(account.contacts)
    expect(results_second_phone.pluck(:id)).to eq([person.id])

    results_fragment = Search::ContactQuery.new('8889900').apply(account.contacts)
    expect(results_fragment.pluck(:id)).to eq([person.id])

    results_shared = Search::ContactQuery.new('+7 701 222 33 44').apply(account.contacts)
    expect(results_shared.pluck(:id)).to contain_exactly(person.id, child.id)
  end

  it 'preserves 2nd personal phones and repoints shared family dependents during ContactMergeAction (P1-1)', :aggregate_failures do
    duplicate = create(:contact, account: account, name: 'Данияр Телеграм', phone_number: '+77081112233')
    Contacts::PhoneManagementService.new(account: account, contact: person).add!(
      raw_phone: '+77081112233',
      link_shared: true
    )
    child = create(:contact, account: account, name: 'Сын Данияра', phone_number: nil)
    Contacts::PhoneManagementService.new(account: account, contact: child).add!(
      raw_phone: '+77081112233',
      link_shared: true
    )

    merged = ContactMergeAction.new(
      account: account,
      base_contact: person.reload,
      mergee_contact: duplicate.reload
    ).perform

    owned_phones = merged.reload.contact_phones.where(shared: false).pluck(:phone_number)
    expect(owned_phones).to contain_exactly('+77012223344', '+77078889900', '+77081112233')

    child_cp = child.reload.contact_phones.find_by(phone_number: '+77081112233')
    expect(child_cp).to be_present
    expect(child_cp.owner_contact_id).to eq(person.id)
    expect(child.custom_attributes[Contacts::SharedPhone::SHARED_OWNER_KEY]).to eq(person.id)
  end

  it 'keeps shared family link and mom tab when phone-less child gets their own personal phone (Subcase B2 -> B1, P1-4)', :aggregate_failures do
    child = create(:contact, account: account, name: 'Дочь', phone_number: nil)
    Contacts::PhoneManagementService.new(account: account, contact: child).add!(
      raw_phone: '+77012223344',
      link_shared: true
    )

    Contacts::PhoneManagementService.new(account: account, contact: child.reload).add!(
      raw_phone: '+77059998877',
      label: 'Личный'
    )

    child.reload
    expect(child.phone_number).to eq('+77059998877')
    expect(child.contact_phones.pluck(:phone_number, :primary, :shared)).to contain_exactly(
      ['+77059998877', true, false],
      ['+77012223344', false, true]
    )
    expect(Contacts::SharedPhone.route_contact(child)).to eq(child)
    patients = Scheduling::PatientContextQuery.new(account: account, contact: person.reload).patients
    expect(patients.map(&:id)).to include(person.id, child.id)
  end

  it 'matches 2nd personal phones in Captain::Tools::Account::SearchContactsService (P1-3)' do
    admin = create(:user, account: account, role: :administrator)
    assistant = create(:captain_assistant, account: account)
    allow(Current).to receive(:user).and_return(admin)
    tool = Captain::Tools::Account::SearchContactsService.new(assistant, user: admin)
    result = tool.execute(phone_number: '8 (707) 888-99-00')
    expect(result.to_s).to include(person.name)
  end
end
