require 'rails_helper'

RSpec.describe 'Scheduling patient context', type: :request do
  let(:account) { create(:account).tap { |record| record.enable_features!('scheduling', 'scheduling_finance') } }
  let(:employee) { create(:user, account: account, role: :agent) }
  let(:headers) { employee.create_new_auth_token }
  let(:owner) { create(:contact, account: account, name: 'Mother', last_name: 'Owner', phone_number: '+77001234567') }
  let(:conversation) { create(:conversation, account: account, contact: owner) }
  let(:patients_path) { "/api/v1/accounts/#{account.id}/scheduling/contacts/#{owner.id}/patients" }
  let(:appointments_path) { "/api/v1/accounts/#{account.id}/scheduling/appointments" }
  let(:resource) { create(:scheduling_resource, account: account) }
  let(:patient) do
    create(:contact, account: account, name: 'Child', last_name: 'Patient', phone_number: nil,
                     custom_attributes: {
                       Contacts::SharedPhone::CARD_KEY => true, Contacts::SharedPhone::SHARED_OWNER_KEY => owner.id,
                       Contacts::SharedPhone::SHARED_PHONE_KEY => owner.phone_number, 'secondary_phones' => [owner.phone_number],
                       'iin' => '940720300129', 'birth_date' => '1994-07-20', 'gender' => 'M'
                     })
  end

  before do
    result = Scheduling::AvailabilityService::Result.new(available: true)
    allow(Scheduling::AvailabilityService).to receive(:new).and_return(instance_double(Scheduling::AvailabilityService, availability_result: result))
    allow(Integrations::Medelement::CronScheduleService).to receive(:new).and_return(instance_double(Integrations::Medelement::CronScheduleService, sync!: true))
  end

  def new_appointment_params
    { resource_id: resource.id, contact_id: owner.id, conversation_id: conversation.id, patient_contact_id: patient.id,
      starts_at: 2.days.from_now.change(hour: 10).iso8601, duration_min: 30 }
  end

  it 'lists only the default communication contact and recorded related cards' do
    patient
    create(:contact, account: account, identifier: '940720300129', custom_attributes: { 'iin' => '940720300129' })
    create(:contact, account: account, custom_attributes: {
             Contacts::SharedPhone::SHARED_OWNER_KEY => owner.id, Contacts::SharedPhone::SHARED_PHONE_KEY => owner.phone_number,
             'secondary_phones' => []
           })
    create(:contact, custom_attributes: patient.custom_attributes)

    get patients_path, headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    cards = response.parsed_body.dig('payload', 'patients')
    expect(cards.pluck('id')).to eq([owner.id, patient.id])
    expect(cards.first).to include('patient_contact_id' => nil, 'communication_contact_id' => owner.id)
    expect(cards.last).to include('patient_contact_id' => patient.id, 'selectable_patient' => true)
  end

  it 'requires staff authentication and scopes the communication contact to the account' do
    get patients_path, as: :json
    expect(response).to have_http_status(:unauthorized)
    foreign = create(:contact)
    get "/api/v1/accounts/#{account.id}/scheduling/contacts/#{foreign.id}/patients", headers: headers, as: :json
    expect(response).to have_http_status(:not_found)
  end

  it 'creates a separate local patient from the original dialogue without moving the primary number or history' do
    original_owner = owner.reload.attributes
    original_conversation = conversation.reload.attributes
    post patients_path, params: {
      first_name: 'Child', last_name: 'Patient', middle_name: 'Relative', iin: '940720300129',
      phone: owner.phone_number, birth_date: '1994-07-20', gender: 'M', conversation_display_id: conversation.display_id,
      idempotency_key: 'new-child-card'
    }, headers: headers, as: :json

    expect(response).to have_http_status(:created)
    card = account.contacts.find(response.parsed_body.dig('payload', 'patient_contact_id'))
    expect(card.id).not_to eq(owner.id)
    expect(card).to have_attributes(name: 'Child', last_name: 'Patient', identifier: '940720300129', phone_number: nil)
    expect(Contacts::SharedPhone.share_of(card)).to have_attributes(owner_id: owner.id, conversation_id: conversation.id, phone: owner.phone_number)
    expect(owner.reload.attributes).to eq(original_owner)
    expect(conversation.reload.attributes).to eq(original_conversation)
    expect(Scheduling::Appointment.count).to eq(0)
  end

  it 'never adopts an unrecorded widget-style identity merely because its self-declared IIN matches' do
    unrecorded = create(:contact, account: account, name: 'Unverified', identifier: '940720300129', custom_attributes: { 'iin' => '940720300129' })
    post patients_path, params: { first_name: 'Child', last_name: 'Patient', iin: '940720300129', idempotency_key: 'public-iin-card' }, headers: headers, as: :json
    expect(response).to have_http_status(:created)
    expect(response.parsed_body.dig('payload', 'id')).not_to eq(unrecorded.id)
    expect(unrecorded.reload.name).to eq('Unverified')
  end

  it 'rejects malformed explicit IIN values before creating a trusted local patient card' do
    path = patients_path
    authentication = headers
    %w[123 9407203001290 940720300128 invalid].each do |iin|
      expect do
        post path, params: { first_name: 'Child', last_name: 'Patient', iin: iin, idempotency_key: "invalid-iin-#{iin}" },
                   headers: authentication, as: :json
      end.not_to change(Contact, :count)
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body['code']).to eq('INVALID_IIN')
    end
  end

  it 'keeps an explicitly created card with its own number in the patient group and makes network retries idempotent' do
    params = { first_name: 'Child', last_name: 'Patient', phone: '+77002223344', idempotency_key: 'own-number-card' }
    post patients_path, params: params, headers: headers, as: :json
    expect(response).to have_http_status(:created)
    patient_id = response.parsed_body.dig('payload', 'id')
    expect do
      post patients_path, params: params, headers: headers, as: :json
    end.not_to change(Contact, :count)
    expect(response.parsed_body.dig('payload', 'id')).to eq(patient_id)
    get patients_path, headers: headers, as: :json
    expect(response.parsed_body.dig('payload', 'patients').pluck('id')).to include(patient_id)
    post patients_path, params: params.merge(first_name: 'Different'), headers: headers, as: :json
    expect(response).to have_http_status(:conflict)
  end

  it 'creates an appointment for the selected card with separate patient and communication context' do
    owner_before = owner.reload.attributes
    post appointments_path, params: new_appointment_params, headers: headers, as: :json

    expect(response).to have_http_status(:created), response.parsed_body.inspect
    appointment = account.scheduling_appointments.find(response.parsed_body.dig('payload', 'id'))
    expect(appointment).to have_attributes(contact_id: owner.id, conversation_id: conversation.id, patient_contact_id: patient.id,
                                          client_first_name: 'Child', client_last_name: 'Patient', client_identifier: '940720300129', client_gender: 'M')
    expect(appointment.client_birth_date).to eq(Date.new(1994, 7, 20))
    expect(response.parsed_body.fetch('payload')).to include('patient_context_contact_id' => patient.id,
                                                            'conversation_display_id' => conversation.display_id)
    expect(owner.reload.attributes).to eq(owner_before)
  end

  it 'rejects a foreign card and an unrecorded public identity as the selected patient' do
    foreign = create(:contact, custom_attributes: { Contacts::SharedPhone::CARD_KEY => true })
    post appointments_path, params: new_appointment_params.merge(patient_contact_id: foreign.id), headers: headers, as: :json
    expect(response).to have_http_status(:not_found)
    unrecorded = create(:contact, account: account, identifier: '940720300129', custom_attributes: { 'iin' => '940720300129' })
    post appointments_path, params: new_appointment_params.merge(patient_contact_id: unrecorded.id), headers: headers, as: :json
    expect(response).to have_http_status(:conflict)
    expect(account.scheduling_appointments).to be_empty
  end

  it 'rejects changing or clearing the strong identity on the selected patient' do
    post appointments_path, params: new_appointment_params.merge(client_identifier: '000101300019'), headers: headers, as: :json
    expect(response).to have_http_status(:conflict)
    post appointments_path, params: new_appointment_params.merge(client_identifier: ''), headers: headers, as: :json
    expect(response).to have_http_status(:conflict)
    expect(account.scheduling_appointments).to be_empty
  end

  it 'preserves the linked name fence even when the same selected card has no known IIN or command history' do
    card = create(:contact, account: account, name: 'Child', last_name: 'Patient', custom_attributes: { 'medelement_patient_code' => 'known-patient' })
    appointment = create(:scheduling_appointment, account: account, resource: resource, contact: owner, patient_contact: card,
                                                  client_first_name: 'Child', client_last_name: 'Patient', client_identifier: nil,
                                                  external_ref: 'medelement:reception:existing', custom_attributes: {
                                                    Integrations::Medelement::AppointmentPatientIdentity::OWNED_IDENTITY_KEY => true
                                                  })
    patch "#{appointments_path}/#{appointment.id}", params: {
      patient_contact_id: card.id, client_first_name: 'Other', client_last_name: 'Person'
    }, headers: headers, as: :json
    expect(response).to have_http_status(:conflict)
    expect(appointment.reload.client_first_name).to eq('Child')
  end

  it 'preserves conflicting recorded provider references even on the same selected card' do
    card = create(:contact, account: account, name: 'Child', last_name: 'Patient', custom_attributes: { 'medelement_patient_code' => 'card-reference' })
    appointment = create(:scheduling_appointment, account: account, resource: resource, contact: owner, patient_contact: card,
                                                  client_first_name: 'Child', client_last_name: 'Patient', client_identifier: nil,
                                                  custom_attributes: { 'medelement_patient_code' => 'captured-reference',
                                                                       Integrations::Medelement::AppointmentPatientIdentity::OWNED_IDENTITY_KEY => true })
    patch "#{appointments_path}/#{appointment.id}", params: { patient_contact_id: card.id, client_comment: 'Comment' }, headers: headers, as: :json
    expect(response).to have_http_status(:conflict)
    expect(appointment.reload.custom_attributes['medelement_patient_code']).to eq('captured-reference')
  end

  it 'keeps a real previous patient card unchanged when another draft appointment switches patients' do
    previous = create(:contact, account: account, name: 'Previous', last_name: 'Patient', phone_number: nil,
                               custom_attributes: { Contacts::SharedPhone::CARD_KEY => true, Contacts::SharedPhone::SHARED_OWNER_KEY => owner.id,
                                                    Contacts::SharedPhone::SHARED_PHONE_KEY => owner.phone_number, 'secondary_phones' => [owner.phone_number] })
    target = create(:scheduling_appointment, account: account, resource: resource, contact: owner, patient_contact: previous,
                                           client_first_name: 'Previous', client_last_name: 'Patient', client_identifier: nil,
                                           custom_attributes: { Integrations::Medelement::AppointmentPatientIdentity::OWNED_IDENTITY_KEY => true })
    create(:scheduling_appointment, account: account, resource: resource, contact: owner, patient_contact: previous)
    previous_before = previous.reload.attributes
    patch "#{appointments_path}/#{target.id}", params: { patient_contact_id: patient.id }, headers: headers, as: :json
    expect(response).to have_http_status(:ok), response.parsed_body.inspect
    expect(target.reload.patient_contact_id).to eq(patient.id)
    expect(previous.reload.attributes).to eq(previous_before)
  end

  it 'uses the verified communication owner as an explicitly selected existing patient without changing its profile' do
    owner.update!(identifier: '940720300129', custom_attributes: { 'medelement_patient_code' => 'verified-owner', 'medelement_iin' => '940720300129' })
    owner_before = owner.reload.attributes
    post appointments_path, params: new_appointment_params.merge(patient_contact_id: owner.id), headers: headers, as: :json
    expect(response).to have_http_status(:created), response.parsed_body.inspect
    appointment = account.scheduling_appointments.find(response.parsed_body.dig('payload', 'id'))
    expect(appointment.patient_contact_id).to eq(owner.id)
    expect(owner.reload.attributes).to eq(owner_before)
  end

  it 'projects the recorded clinical profile into the selector and books it while preserving the chat alias' do
    owner.update!(identifier: '940720300129', custom_attributes: {
                    'medelement_patient_code' => 'verified-owner', 'medelement_iin' => '940720300129',
                    'medelement_first_name' => 'Clinical', 'medelement_last_name' => 'Patient', 'medelement_middle_name' => 'Relative',
                    'medelement_birth_date' => '20.07.1994', 'medelement_gender' => '2',
                    'birth_date' => '1980-01-01', 'gender' => 'female'
                  })
    owner_before = owner.reload.attributes
    get patients_path, headers: headers, as: :json
    expect(response).to have_http_status(:ok)
    selected = response.parsed_body.dig('payload', 'patients').find { |item| item['id'] == owner.id }
    expect(selected).to include('first_name' => 'Clinical', 'last_name' => 'Patient', 'middle_name' => 'Relative',
                                'full_name' => 'Clinical Patient Relative', 'identifier' => '940720300129',
                                'birth_date' => '1994-07-20', 'gender' => '2', 'patient_contact_id' => owner.id)

    post appointments_path, params: {
      resource_id: resource.id, contact_id: owner.id, conversation_id: conversation.id, patient_contact_id: selected['patient_contact_id'],
      starts_at: 2.days.from_now.change(hour: 10).iso8601, duration_min: 30,
      client_first_name: selected['first_name'], client_last_name: selected['last_name'], client_middle_name: selected['middle_name'],
      client_identifier: selected['identifier'], client_birth_date: selected['birth_date'], client_gender: selected['gender'], client_phone: selected['phone']
    }, headers: headers, as: :json
    expect(response).to have_http_status(:created), response.parsed_body.inspect
    appointment = account.scheduling_appointments.find(response.parsed_body.dig('payload', 'id'))
    expect(appointment).to have_attributes(contact_id: owner.id, patient_contact_id: owner.id, client_first_name: 'Clinical',
                                          client_last_name: 'Patient', client_middle_name: 'Relative', client_identifier: '940720300129',
                                          client_birth_date: Date.new(1994, 7, 20), client_gender: '2')
    expect(owner.reload.attributes).to eq(owner_before)
  end

  it 'filters default legacy appointments separately from each bound patient card' do
    legacy = create(:scheduling_appointment, account: account, resource: resource, contact: owner)
    selected = create(:scheduling_appointment, account: account, resource: resource, contact: owner, patient_contact: patient)
    get appointments_path, params: { contact_ids: owner.id.to_s, patient_contact_ids: owner.id.to_s }, headers: headers, as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch('payload').pluck('id')).to eq([legacy.id])
    get appointments_path, params: { contact_ids: owner.id.to_s, patient_contact_ids: patient.id.to_s }, headers: headers, as: :json
    expect(response.parsed_body.fetch('payload').pluck('id')).to eq([selected.id])
  end

  it 'returns only a recoverable prewrite patient conflict alongside active commands, without running a provider write' do
    resource.update!(custom_attributes: { 'medelement_specialist_code' => 'specialist-1',
                                          'medelement_cabinets' => [{ 'companyCabinetCode' => 'cabinet-1' }] })
    appointment = create(:scheduling_appointment, account: account, resource: resource, contact: owner, patient_contact: patient,
                                                  client_first_name: 'Child', client_last_name: 'Patient', client_identifier: patient.custom_attributes['iin'],
                                                  custom_attributes: { 'medelement_cabinet_code' => 'cabinet-1',
                                                                       Integrations::Medelement::AppointmentPatientIdentity::OWNED_IDENTITY_KEY => true })
    hook = create(:integrations_hook, :medelement, account: account,
                                                settings: attributes_for(:integrations_hook, :medelement)[:settings].merge('write_enabled' => true))
    command = Integrations::Medelement::ProviderCommands::CreateService.new(
      account: account, hook: hook, appointment: appointment, actor: employee, operation: 'create_reception',
      company_cabinet_code: 'cabinet-1', idempotency_key: 'recoverable-prewrite',
      desired_starts_at: appointment.starts_at, desired_ends_at: appointment.ends_at
    ).perform
    command.confirmation_request.update!(status: 'confirmed', resolved_at: Time.current)
    command.update!(status: 'failed', last_error_code: 'patient_ref_conflict')
    path = "/api/v1/accounts/#{account.id}/scheduling/provider_commands"

    expect do
      get path, params: { active_only: true, appointment_id: appointment.id }, headers: headers, as: :json
    end.not_to have_enqueued_job(Integrations::Medelement::ProviderCommandJob)
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch('payload')).to contain_exactly(hash_including(
      'id' => command.id, 'status' => 'failed', 'patient_action' => hash_including('type' => 'patient_selection', 'can_confirm' => true)
    ))

    command.update!(execution_state: command.execution_state.merge('write_provider_patient_code' => 'attempted'))
    get path, params: { active_only: true, appointment_id: appointment.id }, headers: headers, as: :json
    expect(response.parsed_body.fetch('payload')).to be_empty
  end
end
