require 'rails_helper'

RSpec.describe Integrations::Medelement::ContactResolverService do
  let(:account) { create(:account) }
  let(:client) { instance_double(Integrations::Medelement::Client) }
  let(:service) { described_class.new(account: account, client: client, organization_id: 'company-1') }
  let(:patient_code) { '550990851604984873' }
  let(:primary_phone) { ['+7', '701', '523', '5543'].join }
  let(:secondary_phone) { ['+7', '777', '111', '2233'].join }
  let(:patient_payload) do
    {
      'PROFILE_CODE' => patient_code,
      'FULLNAME' => 'Сулейменова Светлана Темирбаевна',
      'LASTNAME' => 'Сулейменова',
      'MIDDLENAME' => 'Темирбаевна',
      'BIRTHDAY' => '14.09.1972',
      'GENDER' => 1,
      'IIN' => '720914402646',
      'PATIENT_PHONE_2_STR' => '+7 701 5235543',
      'PATIENT_PHONE_3_STR' => '8 777 1112233',
      'PATIENT_EMAIL' => 'patient@example.com',
      'FULL_ADDRESS' => 'Almaty'
    }
  end

  before do
    allow(client).to receive(:search_patients_by_codes).with(patient_codes: [patient_code]).and_return([patient_payload])
  end

  it 'creates a contact and stores Medelement metadata', :aggregate_failures do
    allow(client).to receive(:get_patient).with(patient_code: patient_code).and_return(patient_payload)

    contact = service.sync_patient!(patient_code)

    expect(contact.name).to eq('Светлана')
    expect(contact.last_name).to eq('Сулейменова')
    expect(contact.middle_name).to eq('Темирбаевна')
    expect(contact.custom_attributes['medelement_middle_name']).to eq('Темирбаевна')
    expect(contact.identifier).to eq('720914402646')
    expect(contact.phone_number).to eq(primary_phone)
    expect(contact.email).to eq('patient@example.com')
    expect(contact.additional_attributes['country_code']).to eq('KZ')
    expect(contact.additional_attributes['country']).to eq('Kazakhstan')
    expect(contact.custom_attributes['medelement_patient_code']).to eq(patient_code)
    expect(contact.custom_attributes['secondary_phones']).to eq([secondary_phone])
  end

  it 'rejects a patient that explicitly belongs to another provider organization' do
    scoped_service = described_class.new(account: account, client: client, organization_id: 'company-1')
    allow(client).to receive(:get_patient).with(patient_code: patient_code).and_return(
      patient_payload.merge('COMPANY_CODE' => 'company-2')
    )

    expect { scoped_service.sync_patient!(patient_code) }
      .to raise_error(Integrations::Medelement::ProviderScope::MismatchError)
    expect(account.contacts).to be_empty
  end

  it 'rejects an unmarked direct payload whose patient code differs from the requested reference' do
    allow(client).to receive(:get_patient).with(patient_code: patient_code).and_return(
      patient_payload.merge('PROFILE_CODE' => 'other-patient')
    )
    allow(client).to receive(:search_patients_by_codes)

    expect { service.sync_patient!(patient_code) }
      .to raise_error(Integrations::Medelement::ProviderScope::MismatchError)
    expect(client).not_to have_received(:search_patients_by_codes)
    expect(account.contacts).to be_empty
  end

  it 'rejects an unmarked payload when the preferred Contact has no trusted identity anchor' do
    contact = create(:contact, account: account, name: 'Unverified')
    allow(client).to receive(:search_patients_by_codes)

    expect { service.sync_patient_payload!(patient_payload, preferred_contact: contact) }
      .to raise_error(Integrations::Medelement::ProviderScope::MismatchError)
    expect(client).not_to have_received(:search_patients_by_codes)
    expect(contact.reload).to have_attributes(name: 'Unverified', identifier: nil, phone_number: nil)
  end

  it 'does not create a Contact when direct and indexed provider identities disagree' do
    conflict_tracker = instance_double(Integrations::Medelement::ConflictTracker, record!: true)
    resolver = described_class.new(
      account: account,
      client: client,
      conflict_tracker: conflict_tracker,
      organization_id: 'company-1'
    )
    allow(client).to receive(:get_patient).with(patient_code: patient_code).and_return(
      patient_payload.merge('NAME' => 'Direct')
    )
    allow(client).to receive(:search_patients_by_codes).with(patient_codes: [patient_code]).and_return(
      [patient_payload.merge('NAME' => 'Indexed')]
    )

    expect(resolver.sync_patient!(patient_code)).to be_nil
    expect(account.contacts).to be_empty
    expect(conflict_tracker).to have_received(:record!).with(
      hash_including(
        conflict_type: 'patient_read_model_conflict',
        entity_key: patient_code,
        details: { reason: 'Provider patient read models disagree' }
      )
    )
  end

  it 'rejects a foreign linked patient before consulting the indexed read model' do
    contact = create(
      :contact,
      account: account,
      custom_attributes: {
        'medelement_patient_code' => patient_code,
        'medelement_last_synced_at' => 2.days.ago.iso8601
      }
    )
    scoped_service = described_class.new(account: account, client: client, organization_id: 'company-1')
    allow(client).to receive(:get_patient).with(patient_code: patient_code).and_return(
      patient_payload.merge('COMPANY_CODE' => 'company-2')
    )
    allow(client).to receive(:search_patients_by_codes)

    expect { scoped_service.sync_patient!(patient_code) }
      .to raise_error(Integrations::Medelement::ProviderScope::MismatchError)
    expect(client).not_to have_received(:search_patients_by_codes)
    expect(contact.reload.custom_attributes['medelement_patient_code']).to eq(patient_code)
  end

  it 'accepts legacy patient responses without a company code' do
    scoped_service = described_class.new(account: account, client: client, organization_id: 'company-1')
    allow(client).to receive(:get_patient).with(patient_code: patient_code).and_return(patient_payload)

    expect(scoped_service.sync_patient!(patient_code)).to be_persisted
  end

  it 'does not overwrite a phone that already belongs to another contact' do
    create(:contact, account: account, phone_number: primary_phone)
    allow(client).to receive(:get_patient).with(patient_code: patient_code).and_return(patient_payload)

    contact = service.sync_patient!(patient_code)

    expect(contact.phone_number).to be_blank
    expect(contact.custom_attributes['phone_conflict_comment']).to include(primary_phone)
    expect(contact.custom_attributes['secondary_phones']).to contain_exactly(primary_phone, secondary_phone)
  end

  it 'links a unique existing Contact by a valid IIN stored in custom attributes' do
    existing_contact = create(
      :contact,
      account: account,
      name: 'Existing patient',
      custom_attributes: { 'iin' => patient_payload['IIN'] }
    )
    allow(client).to receive(:get_patient).with(patient_code: patient_code).and_return(patient_payload)

    resolved_contact = service.sync_patient!(patient_code)
    repeated_contact = service.sync_patient!(patient_code)

    expect(resolved_contact.id).to eq(existing_contact.id)
    expect(repeated_contact.id).to eq(existing_contact.id)
    expect(account.contacts.count).to eq(1)
    expect(resolved_contact.reload.custom_attributes['medelement_patient_code']).to eq(patient_code)
  end

  it 'does not replace a different MedElement patient mapping found through the same IIN' do
    existing_contact = create(
      :contact,
      account: account,
      identifier: patient_payload['IIN'],
      custom_attributes: {
        'iin' => patient_payload['IIN'],
        'medelement_patient_code' => 'another-patient'
      }
    )
    allow(client).to receive(:get_patient).with(patient_code: patient_code).and_return(patient_payload)

    resolved_contact = service.sync_patient!(patient_code)

    expect(resolved_contact.id).not_to eq(existing_contact.id)
    expect(existing_contact.reload.custom_attributes['medelement_patient_code']).to eq('another-patient')
    expect(account.contacts.count).to eq(2)
  end

  it 'does not link a Contact with conflicting valid IIN fields' do
    existing_contact = create(
      :contact,
      account: account,
      identifier: '940720300129',
      custom_attributes: { 'iin' => patient_payload['IIN'] }
    )
    allow(client).to receive(:get_patient).with(patient_code: patient_code).and_return(patient_payload)

    resolved_contact = service.sync_patient!(patient_code)

    expect(resolved_contact.id).not_to eq(existing_contact.id)
    expect(existing_contact.reload.custom_attributes['medelement_patient_code']).to be_blank
    expect(account.contacts.count).to eq(2)
  end

  it 'links a unique phone candidate only when valid IIN, full name and birth date corroborate it' do
    existing_contact = create(
      :contact,
      account: account,
      name: 'Светлана',
      last_name: 'Сулейменова',
      middle_name: 'Темирбаевна',
      phone_number: primary_phone,
      custom_attributes: { 'birth_date' => '1972-09-14' }
    )
    allow(client).to receive(:get_patient).with(patient_code: patient_code).and_return(patient_payload)

    resolved_contact = service.sync_patient!(patient_code)

    expect(resolved_contact.id).to eq(existing_contact.id)
    expect(account.contacts.count).to eq(1)
    expect(resolved_contact.reload).to have_attributes(identifier: patient_payload['IIN'], phone_number: primary_phone)
    expect(resolved_contact.custom_attributes['medelement_patient_code']).to eq(patient_code)
  end

  it 'links a unique email candidate only when valid IIN, full name and birth date corroborate it' do
    existing_contact = create(
      :contact,
      account: account,
      name: 'Светлана',
      last_name: 'Сулейменова',
      middle_name: 'Темирбаевна',
      email: patient_payload['PATIENT_EMAIL'],
      custom_attributes: { 'birth_date' => '1972-09-14' }
    )
    allow(client).to receive(:get_patient).with(patient_code: patient_code).and_return(patient_payload)

    resolved_contact = service.sync_patient!(patient_code)

    expect(resolved_contact.id).to eq(existing_contact.id)
    expect(account.contacts.count).to eq(1)
    expect(resolved_contact.reload.identifier).to eq(patient_payload['IIN'])
    expect(resolved_contact.custom_attributes['medelement_patient_code']).to eq(patient_code)
  end

  it 'does not link by email alone without matching demographic evidence' do
    existing_contact = create(
      :contact,
      account: account,
      name: 'Shared family email',
      email: patient_payload['PATIENT_EMAIL']
    )
    allow(client).to receive(:get_patient).with(patient_code: patient_code).and_return(patient_payload)

    resolved_contact = service.sync_patient!(patient_code)

    expect(resolved_contact.id).not_to eq(existing_contact.id)
    expect(resolved_contact.email).to be_blank
    expect(account.contacts.count).to eq(2)
  end

  it 'does not auto-link when different provider phones identify multiple demographic matches' do
    matching_attributes = {
      account: account,
      name: 'Светлана',
      last_name: 'Сулейменова',
      middle_name: 'Темирбаевна',
      custom_attributes: { 'birth_date' => '1972-09-14' }
    }
    matching_contacts = [
      create(:contact, **matching_attributes, phone_number: primary_phone),
      create(:contact, **matching_attributes, phone_number: secondary_phone)
    ]
    allow(client).to receive(:get_patient).with(patient_code: patient_code).and_return(patient_payload)

    resolved_contact = service.sync_patient!(patient_code)

    expect(matching_contacts.map(&:id)).not_to include(resolved_contact.id)
    expect(resolved_contact.phone_number).to be_blank
    expect(matching_contacts).to all(satisfy { |contact| contact.reload.custom_attributes['medelement_patient_code'].blank? })
    expect(account.contacts.count).to eq(3)
  end

  it 'does not link a phone candidate that has a different valid IIN' do
    existing_contact = create(
      :contact,
      account: account,
      name: 'Светлана',
      last_name: 'Сулейменова',
      middle_name: 'Темирбаевна',
      phone_number: primary_phone,
      identifier: '940720300129',
      custom_attributes: { 'birth_date' => '1972-09-14', 'iin' => '940720300129' }
    )
    allow(client).to receive(:get_patient).with(patient_code: patient_code).and_return(patient_payload)

    resolved_contact = service.sync_patient!(patient_code)

    expect(resolved_contact.id).not_to eq(existing_contact.id)
    expect(resolved_contact.phone_number).to be_blank
    expect(existing_contact.reload.custom_attributes['medelement_patient_code']).to be_blank
    expect(account.contacts.count).to eq(2)
  end

  it 'does not link by phone and demographics when the provider IIN is missing' do
    existing_contact = create(
      :contact,
      account: account,
      name: 'Светлана',
      last_name: 'Сулейменова',
      middle_name: 'Темирбаевна',
      phone_number: primary_phone,
      custom_attributes: { 'birth_date' => '1972-09-14' }
    )
    payload_without_iin = patient_payload.except('IIN')
    allow(client).to receive(:get_patient).with(patient_code: patient_code).and_return(payload_without_iin)
    allow(client).to receive(:search_patients_by_codes).with(patient_codes: [patient_code]).and_return([payload_without_iin])

    resolved_contact = service.sync_patient!(patient_code)

    expect(resolved_contact.id).not_to eq(existing_contact.id)
    expect(resolved_contact.phone_number).to be_blank
    expect(account.contacts.count).to eq(2)
  end

  it 'does not treat a short provider identifier as a valid IIN for phone matching' do
    existing_contact = create(
      :contact,
      account: account,
      name: 'Светлана',
      last_name: 'Сулейменова',
      middle_name: 'Темирбаевна',
      phone_number: primary_phone,
      custom_attributes: { 'birth_date' => '1972-09-14' }
    )
    payload_with_invalid_iin = patient_payload.merge('IIN' => '1234')
    allow(client).to receive(:get_patient).with(patient_code: patient_code).and_return(payload_with_invalid_iin)
    allow(client).to receive(:search_patients_by_codes).with(patient_codes: [patient_code]).and_return(
      [payload_with_invalid_iin]
    )

    resolved_contact = service.sync_patient!(patient_code)

    expect(resolved_contact.id).not_to eq(existing_contact.id)
    expect(resolved_contact.phone_number).to be_blank
    expect(account.contacts.count).to eq(2)
  end

  it 'keeps the Contact phone and surfaces a different provider phone for review' do
    contact_phone = ['+7', '700', '111', '2233'].join
    contact = create(
      :contact,
      account: account,
      phone_number: contact_phone,
      custom_attributes: { 'medelement_patient_code' => patient_code }
    )

    resolved_contact = service.sync_patient_payload!(patient_payload, preferred_contact: contact)

    expect(resolved_contact.reload.phone_number).to eq(contact_phone)
    expect(resolved_contact.custom_attributes['secondary_phones']).to contain_exactly(primary_phone, secondary_phone)
    expect(resolved_contact.custom_attributes['phone_conflict_comment']).to include(primary_phone, 'current Contact phone')
  end

  it 'guards provider-command payload synchronization against direct and indexed identity conflicts' do
    contact = create(
      :contact,
      account: account,
      name: 'Current',
      last_name: 'Patient',
      middle_name: 'Identity',
      custom_attributes: { 'medelement_patient_code' => patient_code }
    )
    direct_patient = patient_payload.merge('NAME' => 'Stale', 'LASTNAME' => 'Version', 'MIDDLENAME' => 'Direct')
    indexed_patient = patient_payload.merge('NAME' => 'Current', 'LASTNAME' => 'Patient', 'MIDDLENAME' => 'Identity')
    allow(client).to receive(:search_patients_by_codes).with(patient_codes: [patient_code]).and_return([indexed_patient])

    resolved_contact = service.sync_patient_payload!(direct_patient, preferred_contact: contact)

    expect(resolved_contact.reload).to have_attributes(name: 'Current', last_name: 'Patient', middle_name: 'Identity')
  end

  it 'preserves structured names when a direct payload omits fields present in the indexed model' do
    contact = create(
      :contact,
      account: account,
      name: 'Current',
      last_name: 'Patient',
      middle_name: 'Identity',
      custom_attributes: {
        'medelement_patient_code' => patient_code,
        'medelement_last_name' => 'Patient',
        'medelement_middle_name' => 'Identity'
      }
    )
    partial_direct = patient_payload.except('LASTNAME', 'MIDDLENAME').merge('NAME' => 'Current')
    indexed_patient = patient_payload.merge('NAME' => 'Current', 'LASTNAME' => 'Patient', 'MIDDLENAME' => 'Identity')
    allow(client).to receive(:search_patients_by_codes).with(patient_codes: [patient_code]).and_return([indexed_patient])

    service.sync_patient_payload!(partial_direct, preferred_contact: contact)

    expect(contact.reload).to have_attributes(name: 'Current', last_name: 'Patient', middle_name: 'Identity')
    expect(contact.custom_attributes).to include(
      'medelement_last_name' => 'Patient',
      'medelement_middle_name' => 'Identity'
    )
  end

  it 'preserves local secondary phones while merging normalized provider phones' do
    local_secondary_phone = ['+7', '705', '222', '3344'].join
    contact = create(
      :contact,
      account: account,
      phone_number: primary_phone,
      custom_attributes: { 'secondary_phones' => [local_secondary_phone, '8 (777) 111-22-33'] }
    )

    resolved_contact = service.sync_patient_payload!(patient_payload, preferred_contact: contact)

    expect(resolved_contact.reload.custom_attributes['secondary_phones']).to contain_exactly(
      local_secondary_phone,
      secondary_phone
    )
  end

  it 'accepts the Contact primary phone when it is a secondary provider phone' do
    contact = create(:contact, account: account, phone_number: secondary_phone)

    resolved_contact = service.sync_patient_payload!(patient_payload, preferred_contact: contact)

    expect(resolved_contact.reload.phone_number).to eq(secondary_phone)
    expect(resolved_contact.custom_attributes['phone_conflict_comment']).to be_blank
    expect(resolved_contact.custom_attributes['secondary_phones']).to contain_exactly(primary_phone)
  end

  it 'does not refresh a fresh contact' do
    contact = create(
      :contact,
      account: account,
      custom_attributes: {
        'medelement_patient_code' => patient_code,
        'medelement_last_synced_at' => Time.current.iso8601
      }
    )
    allow(client).to receive(:get_patient)

    resolved_contact = service.sync_patient!(patient_code)

    expect(client).not_to have_received(:get_patient)
    expect(resolved_contact.id).to eq(contact.id)
  end

  it 'does not refresh a fresh explicitly linked contact' do
    contact = create(
      :contact,
      account: account,
      custom_attributes: {
        'medelement_patient_code' => patient_code,
        'medelement_last_synced_at' => Time.current.iso8601
      }
    )
    allow(client).to receive(:get_patient)

    resolved_contact = service.sync_patient!(patient_code, preferred_contact: contact)

    expect(client).not_to have_received(:get_patient)
    expect(resolved_contact.id).to eq(contact.id)
  end

  it 'preserves a Contact with a foreign owner and records an integrity conflict' do
    foreign_owner = create(:user, account: create(:account))
    contact = create(
      :contact,
      account: account,
      name: 'Current name',
      custom_attributes: { 'medelement_patient_code' => patient_code }
    )
    # rubocop:disable Rails/SkipsModelValidations
    contact.update_column(:owner_id, foreign_owner.id)
    # rubocop:enable Rails/SkipsModelValidations
    conflict_tracker = instance_double(Integrations::Medelement::ConflictTracker, record!: nil)
    scoped_service = described_class.new(
      account: account,
      client: client,
      conflict_tracker: conflict_tracker,
      organization_id: 'company-1'
    )
    allow(client).to receive(:get_patient).with(patient_code: patient_code).and_return(patient_payload)

    resolved_contact = scoped_service.sync_patient!(patient_code, preferred_contact: contact)

    expect(resolved_contact.reload).to have_attributes(name: 'Current name', owner_id: foreign_owner.id)
    expect(conflict_tracker).to have_received(:record!).with(
      hash_including(conflict_type: 'foreign_contact_owner', entity_key: patient_code, severity: 'error')
    )
  end

  it 'preserves the Contact and records a conflict when provider read models disagree' do
    contact = create(
      :contact,
      account: account,
      name: 'Current',
      last_name: 'Patient',
      middle_name: 'Identity',
      identifier: '720914402646',
      custom_attributes: {
        'iin' => '720914402646',
        'medelement_patient_code' => patient_code,
        'medelement_last_synced_at' => 2.days.ago.iso8601
      }
    )
    conflict_tracker = instance_double(Integrations::Medelement::ConflictTracker, record!: true)
    resolver = described_class.new(
      account: account, client: client, conflict_tracker: conflict_tracker, organization_id: 'company-1'
    )
    direct_patient = patient_payload.merge('NAME' => 'Stale', 'LASTNAME' => 'Version', 'MIDDLENAME' => 'Direct')
    indexed_patient = patient_payload.merge('NAME' => 'Current', 'LASTNAME' => 'Patient', 'MIDDLENAME' => 'Identity')
    allow(client).to receive(:get_patient).with(patient_code: patient_code).and_return(direct_patient)
    allow(client).to receive(:search_patients_by_codes).with(patient_codes: [patient_code]).and_return([indexed_patient])

    resolved_contact = resolver.sync_patient!(patient_code)

    expect(resolved_contact.reload).to have_attributes(name: 'Current', last_name: 'Patient', middle_name: 'Identity')
    expect(conflict_tracker).to have_received(:record!).with(
      hash_including(
        phase: 'contacts',
        entity_type: 'contact',
        conflict_type: 'patient_read_model_conflict',
        entity_key: patient_code,
        severity: 'error',
        details: { reason: 'Provider patient read models disagree', contact_id: contact.id }
      )
    )
  end

  it 'preserves the Contact when the indexed payload cannot verify every direct identity field' do
    contact = create(
      :contact,
      account: account,
      name: 'Stale',
      last_name: 'Version',
      middle_name: 'Direct',
      custom_attributes: {
        'medelement_patient_code' => patient_code,
        'medelement_last_synced_at' => 2.days.ago.iso8601
      }
    )
    direct_patient = patient_payload.merge('NAME' => 'Current', 'LASTNAME' => 'Patient', 'MIDDLENAME' => 'Identity')
    allow(client).to receive(:get_patient).with(patient_code: patient_code).and_return(direct_patient)
    allow(client).to receive(:search_patients_by_codes).with(patient_codes: [patient_code]).and_return(
      [{ 'PROFILE_CODE' => patient_code }]
    )
    conflict_tracker = instance_double(Integrations::Medelement::ConflictTracker, record!: true)
    resolver = described_class.new(
      account: account, client: client, conflict_tracker: conflict_tracker, organization_id: 'company-1'
    )

    resolver.sync_patient!(patient_code)

    expect(contact.reload).to have_attributes(name: 'Stale', last_name: 'Version', middle_name: 'Direct')
    expect(conflict_tracker).to have_received(:record!).with(
      hash_including(conflict_type: 'patient_read_model_unavailable', severity: 'error')
    )
  end

  it 'preserves the Contact when the indexed patient is temporarily missing' do
    contact = create(
      :contact,
      account: account,
      name: 'Current',
      last_name: 'Patient',
      middle_name: 'Identity',
      custom_attributes: {
        'medelement_patient_code' => patient_code,
        'medelement_last_synced_at' => 2.days.ago.iso8601
      }
    )
    conflict_tracker = instance_double(Integrations::Medelement::ConflictTracker, record!: true)
    resolver = described_class.new(
      account: account, client: client, conflict_tracker: conflict_tracker, organization_id: 'company-1'
    )
    allow(client).to receive(:get_patient).with(patient_code: patient_code).and_return(
      patient_payload.merge('NAME' => 'Unverified')
    )
    allow(client).to receive(:search_patients_by_codes).with(patient_codes: [patient_code]).and_return([])

    resolver.sync_patient!(patient_code)

    expect(contact.reload).to have_attributes(name: 'Current', last_name: 'Patient', middle_name: 'Identity')
    expect(conflict_tracker).to have_received(:record!).with(
      hash_including(
        conflict_type: 'patient_read_model_unavailable',
        severity: 'error',
        details: { reason: 'Provider indexed patient read is unavailable', contact_id: contact.id }
      )
    )
  end

  it 'preserves the Contact when indexed patient lookup fails' do
    contact = create(
      :contact,
      account: account,
      name: 'Current',
      last_name: 'Patient',
      custom_attributes: {
        'medelement_patient_code' => patient_code,
        'medelement_last_synced_at' => 2.days.ago.iso8601
      }
    )
    conflict_tracker = instance_double(Integrations::Medelement::ConflictTracker, record!: true)
    resolver = described_class.new(
      account: account, client: client, conflict_tracker: conflict_tracker, organization_id: 'company-1'
    )
    allow(client).to receive(:get_patient).with(patient_code: patient_code).and_return(
      patient_payload.merge('NAME' => 'Unverified')
    )
    allow(client).to receive(:search_patients_by_codes).with(patient_codes: [patient_code]).and_raise(
      Integrations::Medelement::Client::ApiError.new('temporary failure', status: 503)
    )

    resolver.sync_patient!(patient_code)

    expect(contact.reload).to have_attributes(name: 'Current', last_name: 'Patient')
    expect(conflict_tracker).to have_received(:record!).with(
      hash_including(conflict_type: 'patient_read_model_unavailable', severity: 'error')
    )
  end
end
