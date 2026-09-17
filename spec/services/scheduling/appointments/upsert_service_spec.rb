require 'rails_helper'

RSpec.describe Scheduling::Appointments::UpsertService do
  let(:account) { create(:account) }
  let(:resource) { create(:scheduling_resource, account: account) }
  let(:appointment) { create(:scheduling_appointment, account: account, resource: resource) }

  def perform(params)
    described_class.new(account: account, appointment: appointment, params: params).perform
  end

  it 'dispatches persisted update changes before reloading the appointment' do
    dispatcher = Rails.configuration.dispatcher
    allow(dispatcher).to receive(:dispatch)

    perform(client_comment: 'Changed')

    expect(dispatcher).to have_received(:dispatch).with(
      Events::Types::APPOINTMENT_UPDATED,
      anything,
      hash_including(
        appointment: appointment,
        changed_attributes: hash_including('client_comment' => [nil, 'Changed'])
      )
    )
  end

  it 'preserves historical compensation on an ordinary update after resource compensation changes' do
    account.enable_features!('scheduling_finance')
    appointment.update!(
      compensation_type_snapshot: 'fixed',
      compensation_value_snapshot: 1_000,
      compensation_percent_snapshot: 0,
      service_amount: 10_000,
      settlement_amount: 10_000,
      settlement_payment_method: 'cash',
      payment_status: 'paid'
    )
    create(
      :scheduling_expense,
      account: account,
      appointment: appointment,
      resource: resource,
      amount: 1_000
    )
    resource.update!(
      compensation_type: 'fixed',
      compensation_value: 5_000,
      compensation_percent: 0
    )

    perform(client_comment: 'Non-finance change')

    expect(appointment.reload).to have_attributes(
      client_comment: 'Non-finance change',
      compensation_type_snapshot: 'fixed',
      compensation_value_snapshot: 1_000,
      compensation_percent_snapshot: 0
    )
    expect(Scheduling::Expense.find_by!(appointment: appointment)).to have_attributes(amount: 1_000)
  end

  it 'locks the target resource before checking and persisting availability' do
    resources = account.scheduling_resources
    locked_resources = resources.lock
    allow(account).to receive(:scheduling_resources).and_return(resources)
    expect(resources).to receive(:lock).and_return(locked_resources)
    expect(locked_resources).to receive(:find).with(resource.id).and_call_original

    perform(client_comment: 'Serialized')

    expect(appointment.reload.client_comment).to eq('Serialized')
  end

  it 'rejects generic mutations of imported Medelement appointments' do
    appointment.update!(source: 'medelement', external_ref: 'medelement:reception:upsert')

    expect { perform(client_comment: 'Changed') }.to raise_error(Scheduling::Error) do |error|
      expect(error.code).to eq('APPOINTMENT_READ_ONLY')
    end
    expect(appointment.reload.client_comment).to be_nil
  end

  it 'rejects direct assignment of appointment provenance' do
    expect { perform(source: 'medelement') }.to raise_error(Scheduling::Error) do |error|
      expect(error.code).to eq('APPOINTMENT_SOURCE_READ_ONLY')
    end
    expect(appointment.reload.source).to eq('manual')
  end

  it 'reserves Medelement external references for the provider importer' do
    expect { perform(external_ref: ' medelement:reception:spoofed') }.to raise_error(Scheduling::Error) do |error|
      expect(error.code).to eq('APPOINTMENT_EXTERNAL_REF_RESERVED')
    end
    expect(appointment.reload.external_ref).to be_nil
  end

  it 'rejects provider-owned Medelement metadata in manual appointment custom attributes' do
    request = -> { perform(custom_attributes: { 'medelement_reception_code' => 'spoofed' }) }

    expect(&request).to raise_error(Crm::Error) do |error|
      expect(error.code).to eq('VALIDATION_ERROR')
    end
    expect(appointment.reload.custom_attributes).not_to have_key('medelement_reception_code')
  end

  it 'does not let assign own transfer an owned contact through owner_id' do
    agent = create(:user, account: account, role: :agent)
    other_user = create(:user, account: account, role: :agent)
    contact = appointment.contact
    contact.update!(owner: agent)
    AccessControl::LegacyRoleAssigner.call(account: account, apply: true)
    AccessControl::ModeTransition.call(account: account, to: :shadow)
    AccessControl::ModeTransition.call(account: account, to: :enforced)

    expect do
      described_class.new(
        account: account,
        actor: agent,
        appointment: appointment,
        params: { owner_id: other_user.id }
      ).perform
    end.to raise_error(Pundit::NotAuthorizedError)
    expect(contact.reload.owner).to eq(agent)
  end

  it 'rejects the provider source mode while preserving unrelated custom attributes' do
    request = -> { perform(custom_attributes: { 'source_mode' => 'imported', 'note' => 'allowed' }) }

    expect(&request).to raise_error(Crm::Error) do |error|
      expect(error.code).to eq('VALIDATION_ERROR')
    end
    expect(appointment.reload.custom_attributes).to be_empty
  end

  it 'stores structured patient names while requiring only the first name locally' do
    perform(client_first_name: 'Айжан', client_last_name: '', client_middle_name: '')

    expect(appointment.reload).to have_attributes(
      client_first_name: 'Айжан',
      client_last_name: nil,
      client_middle_name: nil,
      client_name: 'Айжан'
    )
  end

  it 'does not populate structured identity from contact fields for non-Medelement appointments' do
    appointment.update!(client_first_name: nil, client_last_name: nil, client_middle_name: nil)
    appointment.contact.update!(name: 'Display name', last_name: 'Касымова', middle_name: 'Ерлановна')

    perform({})

    expect(appointment.reload).to have_attributes(
      client_first_name: nil,
      client_last_name: nil,
      client_middle_name: nil
    )
  end

  it 'rejects an unsupported appointment type at the model runtime boundary' do
    expect { perform(appointment_type: 'Терапевт') }.to raise_error(ActiveRecord::RecordInvalid) do |error|
      expect(error.record.errors.details[:appointment_type]).to include(error: :inclusion, value: 'Терапевт')
    end
  end

  context 'with availability overrides' do
    let(:admin) { create(:user, account: account, role: :administrator) }
    let(:agent) { create(:user, account: account, role: :agent) }
    let(:booking_day) { ActiveSupport::TimeZone[resource.timezone].local(2026, 3, 9, 10, 15, 0) }

    before do
      resource.work_rules.create!(weekday: 1, start_minute: 9 * 60, end_minute: 18 * 60, active: true)
      appointment.update!(starts_at: booking_day.change(hour: 9), ends_at: booking_day.change(hour: 9, min: 30), duration_min: 30)
    end

    def perform_override(actor:, **override_params)
      described_class.new(
        account: account,
        appointment: appointment,
        actor: actor,
        params: {
          starts_at: booking_day.iso8601,
          duration_min: 30
        }.merge(override_params)
      ).perform
    end

    def perform_new_override(actor:, contact:, **override_params)
      described_class.new(
        account: account,
        actor: actor,
        appointment: account.scheduling_appointments.new,
        params: {
          contact_id: contact.id,
          resource_id: resource.id,
          starts_at: booking_day.iso8601,
          duration_min: 30,
          client_name: contact.name
        }.merge(override_params)
      ).perform
    end

    def enforce_override_scope(scope, assign_scope: nil)
      AccessControl::SystemRoleBootstrapper.call(account: account)
      AccessControl::LegacyRoleAssigner.call(account: account, apply: true)
      access_role = account.account_users.find_by!(user: agent).access_role
      override_grant = access_role.grants.find_or_initialize_by(
        account: account,
        resource: 'appointments',
        capability: 'override_schedule'
      )
      override_grant.update!(access_scope: scope)
      access_role.grants.find_by!(resource: 'appointments', capability: 'assign').update!(access_scope: assign_scope) if assign_scope
      account.authorize_access_control_mode_transition { account.update!(access_control_mode: 'enforced') }
    end

    it 'records an authorized break override with its reason and audit comment' do
      resource.break_rules.create!(weekday: 1, start_minute: 10 * 60, end_minute: 11 * 60, active: true)

      perform_override(actor: admin, confirm_break_conflict: true, override_reason: 'Urgent patient')

      override = appointment.reload.custom_attributes.fetch('availability_overrides').last
      expect(override).to include(
        'actor_id' => admin.id,
        'codes' => ['BLOCKED_BY_BREAK'],
        'reason' => 'Urgent patient'
      )
      expect(appointment.audits.last.comment).to include('Urgent patient', 'BLOCKED_BY_BREAK')
    end

    it 'requires a reason for every requested override' do
      expect do
        perform_override(actor: admin, confirm_break_conflict: true)
      end.to raise_error(Scheduling::Error) { |error| expect(error.code).to eq('OVERRIDE_REASON_REQUIRED') }
    end

    it 'rejects an override from an agent without the assigned capability' do
      expect do
        perform_override(actor: agent, confirm_break_conflict: true, override_reason: 'Requested')
      end.to raise_error(Scheduling::Error) { |error| expect(error.code).to eq('OVERRIDE_FORBIDDEN') }
    end

    it 'accepts an enforced override_schedule grant' do
      resource.break_rules.create!(weekday: 1, start_minute: 10 * 60, end_minute: 11 * 60, active: true)
      AccessControl::SystemRoleBootstrapper.call(account: account)
      AccessControl::LegacyRoleAssigner.call(account: account, apply: true)
      account.account_users.find_by!(user: agent).access_role.grants.create!(
        account: account,
        resource: 'appointments',
        capability: 'override_schedule',
        access_scope: 'all'
      )
      account.authorize_access_control_mode_transition do
        account.update!(access_control_mode: 'enforced')
      end

      perform_override(actor: agent, confirm_break_conflict: true, override_reason: 'Assigned override')

      expect(appointment.reload.custom_attributes.fetch('availability_overrides').last).to include(
        'actor_id' => agent.id,
        'codes' => ['BLOCKED_BY_BREAK'],
        'reason' => 'Assigned override'
      )
    end

    it 'accepts an all-scoped override_schedule grant for a new appointment' do
      resource.break_rules.create!(weekday: 1, start_minute: 10 * 60, end_minute: 11 * 60, active: true)
      contact = create(:contact, account: account, owner: agent, name: 'Owned patient')
      enforce_override_scope('all')

      created = perform_new_override(
        actor: agent,
        contact: contact,
        confirm_break_conflict: true,
        override_reason: 'New appointment override'
      )

      expect(created).to be_persisted
      expect(created.custom_attributes.fetch('availability_overrides').last).to include(
        'actor_id' => agent.id,
        'codes' => ['BLOCKED_BY_BREAK']
      )
    end

    %w[own team].each do |scope|
      it "rejects a #{scope} override scope when a new appointment target is outside the scope" do
        resource.break_rules.create!(weekday: 1, start_minute: 10 * 60, end_minute: 11 * 60, active: true)
        contact = create(:contact, account: account, name: 'Unowned patient')
        enforce_override_scope(scope, assign_scope: 'all')

        expect do
          perform_new_override(
            actor: agent,
            contact: contact,
            confirm_break_conflict: true,
            override_reason: "#{scope} override"
          )
        end.to raise_error(Scheduling::Error) { |error| expect(error.code).to eq('OVERRIDE_FORBIDDEN') }
      end
    end

    it 'does not allow personal time off to be bypassed' do
      create(
        :scheduling_time_off,
        account: account,
        resource: resource,
        starts_at: booking_day.change(hour: 10),
        ends_at: booking_day.change(hour: 11)
      )

      expect do
        perform_override(
          actor: admin,
          confirm_break_conflict: true,
          confirm_global_closure: true,
          confirm_outside_working_hours: true,
          confirm_slot_conflict: true,
          override_reason: 'Requested'
        )
      end.to raise_error(Scheduling::Error) { |error| expect(error.code).to eq('BLOCKED_BY_VACATION') }
    end
  end

  context 'when the selected resource belongs to Medelement' do
    def perform(params)
      params = { client_middle_name: 'Ерлановна' }.merge(params) if params.key?(:client_first_name) && !params.key?(:client_middle_name)
      described_class.new(account: account, appointment: appointment, params: params).perform
    end

    let(:valid_phone) { ['+7', '700', '000', '0001'].join }
    let(:service) do
      create(
        :scheduling_service,
        account: account,
        custom_attributes: { 'medelement_nomenclature_code' => 'service-1' }
      )
    end

    before do
      resource.update!(
        custom_attributes: {
          'medelement_specialist_code' => 'specialist-1',
          'medelement_cabinets' => [{ 'companyCabinetCode' => 'cabinet-1' }]
        }
      )
      appointment.update!(
        custom_attributes: appointment.custom_attributes.merge('medelement_cabinet_code' => 'cabinet-1')
      )
    end

    it 'uses structured Medelement contact names when appointment name fields are omitted' do
      appointment.update!(service: nil, custom_attributes: appointment.custom_attributes.except('service_ids', 'services'))
      appointment.contact.update!(
        name: 'Жандаулет Гусман',
        last_name: nil,
        middle_name: nil,
        phone_number: ['+7', '700', '000', '0001'].join,
        custom_attributes: appointment.contact.custom_attributes.merge(
          'medelement_first_name' => 'Жандаулет',
          'medelement_last_name' => 'Гусман',
          'medelement_middle_name' => 'Ерланович'
        )
      )

      perform({})

      expect(appointment.reload).to have_attributes(
        client_first_name: 'Жандаулет',
        client_last_name: 'Гусман',
        client_middle_name: 'Ерланович',
        client_name: 'Жандаулет Гусман Ерланович'
      )
    end

    it 'uses structured top-level contact names when appointment name fields are omitted' do
      appointment.update!(service: nil, custom_attributes: appointment.custom_attributes.except('service_ids', 'services'))
      appointment.contact.update!(
        name: 'Айжан',
        last_name: 'Касымова',
        middle_name: 'Ерлановна',
        phone_number: ['+7', '700', '000', '0001'].join
      )

      perform({})

      expect(appointment.reload).to have_attributes(
        client_first_name: 'Айжан',
        client_last_name: 'Касымова',
        client_middle_name: 'Ерлановна',
        client_name: 'Айжан Касымова Ерлановна'
      )
    end

    it 'does not mix a partial Medelement custom identity with a full display name' do
      appointment.update!(service: nil, custom_attributes: appointment.custom_attributes.except('service_ids', 'services'))
      appointment.contact.update!(
        name: 'Жандаулет Гусман',
        last_name: nil,
        phone_number: ['+7', '700', '000', '0001'].join,
        custom_attributes: appointment.contact.custom_attributes.merge('medelement_last_name' => 'Гусман')
      )

      expect { perform({}) }.to raise_error(Scheduling::Error) do |error|
        expect(error.code).to eq('MEDELEMENT_PATIENT_NAME_INCOMPLETE')
      end
      expect(appointment.reload.client_first_name).to be_nil
    end

    it 'does not fill a missing Medelement custom last name from top-level contact fields' do
      appointment.update!(service: nil, custom_attributes: appointment.custom_attributes.except('service_ids', 'services'))
      appointment.contact.update!(
        name: 'Жандаулет',
        last_name: 'Гусман',
        phone_number: ['+7', '700', '000', '0001'].join,
        custom_attributes: appointment.contact.custom_attributes.merge('medelement_first_name' => 'Жандаулет')
      )

      expect { perform({}) }.to raise_error(Scheduling::Error) do |error|
        expect(error.code).to eq('MEDELEMENT_PATIENT_NAME_INCOMPLETE')
      end
      expect(appointment.reload.client_last_name).to be_nil
    end

    it 'rejects an appointment without a patient last name before persistence' do
      request = -> { perform(client_first_name: 'Айжан', client_last_name: '', client_phone: '+77000000001') }

      expect(&request).to raise_error(Scheduling::Error) do |error|
        expect(error.code).to eq('MEDELEMENT_PATIENT_NAME_INCOMPLETE')
      end

      expect(appointment.reload.client_first_name).to be_nil
    end

    it 'rejects an appointment without a patient middle name before persistence' do
      request = lambda do
        perform(
          client_first_name: 'Айжан',
          client_last_name: 'Касымова',
          client_middle_name: '',
          client_phone: '+770****0001'
        )
      end

      expect(&request).to raise_error(Scheduling::Error) do |error|
        expect(error.code).to eq('MEDELEMENT_PATIENT_NAME_INCOMPLETE')
      end

      expect(appointment.reload.client_first_name).to be_nil
    end

    it 'rejects an appointment without a valid Kazakhstan phone before persistence' do
      request = -> { perform(client_first_name: 'Айжан', client_last_name: 'Касымова', client_phone: '') }

      expect(&request).to raise_error(Scheduling::Error) do |error|
        expect(error.code).to eq('MEDELEMENT_PATIENT_PHONE_INVALID')
      end

      expect(appointment.reload.client_first_name).to be_nil
    end

    it 'rejects an appointment without a Medelement cabinet before persistence' do
      appointment.update!(
        service: nil,
        custom_attributes: appointment.custom_attributes.except('service_ids', 'services', 'medelement_cabinet_code')
      )

      expect do
        perform(resource_id: resource.id, client_first_name: 'Айжан', client_last_name: 'Касымова',
                client_phone: ['+7', '700', '000', '0001'].join)
      end.to raise_error(Scheduling::Error) { |error| expect(error.code).to eq('MEDELEMENT_CABINET_REQUIRED') }
    end

    it 'rejects a Medelement cabinet that does not belong to the selected specialist' do
      appointment.update!(
        service: nil,
        custom_attributes: appointment.custom_attributes.except('service_ids', 'services')
                                                .merge('medelement_cabinet_code' => 'foreign-cabinet')
      )

      expect do
        perform(resource_id: resource.id, client_first_name: 'Айжан', client_last_name: 'Касымова',
                client_phone: ['+7', '700', '000', '0001'].join)
      end.to raise_error(Scheduling::Error) { |error| expect(error.code).to eq('MEDELEMENT_CABINET_INVALID') }
    end

    %w[companyCabinetCode company_cabinet_code COMPANY_CABINET_CODE].each do |cabinet_key|
      it "accepts the #{cabinet_key} resource cabinet format" do
        resource.update!(
          custom_attributes: resource.custom_attributes.merge(
            'medelement_cabinets' => [{ cabinet_key => 'cabinet-1' }]
          )
        )
        appointment.update!(
          service: nil,
          custom_attributes: appointment.custom_attributes.except('service_ids', 'services')
        )

        expect do
          perform(
            resource_id: resource.id,
            client_first_name: 'Айжан',
            client_last_name: 'Касымова',
            client_phone: valid_phone
          )
        end.not_to raise_error
      end
    end

    it 'allows an unrelated update to a legacy appointment without a cabinet' do
      appointment.update!(
        service: nil,
        client_first_name: 'Айжан',
        client_last_name: 'Касымова',
        client_middle_name: 'Ерлановна',
        client_phone: ['+7', '700', '000', '0001'].join,
        custom_attributes: appointment.custom_attributes.except('service_ids', 'services', 'medelement_cabinet_code')
      )

      perform(client_comment: 'Legacy appointment note')

      expect(appointment.reload).to have_attributes(client_comment: 'Legacy appointment note')
      expect(appointment.custom_attributes).not_to have_key('medelement_cabinet_code')
    end

    it 'accepts an appointment without a selected service' do
      appointment.update!(
        service: nil,
        custom_attributes: appointment.custom_attributes.except('service_ids', 'services')
      )
      perform(client_first_name: 'Айжан', client_last_name: 'Касымова', client_phone: '+77000000001')

      expect(appointment.reload).to have_attributes(
        client_first_name: 'Айжан',
        service_id: nil
      )
    end

    it 'rejects a service that is not linked to Medelement before persistence' do
      original_service_id = appointment.service_id
      unmapped_service = create(:scheduling_service, account: account)
      request = lambda do
        perform(
          client_first_name: 'Айжан',
          client_last_name: 'Касымова',
          client_phone: '+77000000001',
          service_id: unmapped_service.id
        )
      end

      expect(&request).to raise_error(Scheduling::Error) do |error|
        expect(error.code).to eq('MEDELEMENT_SERVICE_UNMAPPED')
      end

      expect(appointment.reload.service_id).to eq(original_service_id)
    end

    it 'accepts a complete provider patient identity and mapped service' do
      perform(
        client_first_name: 'Айжан',
        client_last_name: 'Касымова',
        client_phone: '+77000000001',
        service_id: service.id
      )

      expect(appointment.reload).to have_attributes(
        client_first_name: 'Айжан',
        client_last_name: 'Касымова',
        client_phone: '+77000000001',
        service_id: service.id
      )
      expect(appointment.custom_attributes).to include(
        'medelement_service_binding' => 'local_only',
        'medelement_local_nomenclature_codes' => ['service-1'],
        'medelement_provider_nomenclature_codes' => []
      )
    end

    it 'clears the local-only binding when the user removes the selected service' do
      appointment.update!(
        service: service,
        custom_attributes: appointment.custom_attributes.merge(
          'service_ids' => [service.id],
          'medelement_service_binding' => 'local_only',
          'medelement_local_nomenclature_codes' => ['service-1'],
          'medelement_provider_nomenclature_codes' => []
        )
      )

      perform(
        client_first_name: 'Айжан',
        client_last_name: 'Касымова',
        client_phone: '+77000000001',
        service_ids: []
      )

      expect(appointment.reload.service_id).to be_nil
      expect(appointment.custom_attributes).not_to include(
        'medelement_service_binding',
        'medelement_local_nomenclature_codes',
        'medelement_provider_nomenclature_codes'
      )
    end

    it 'accepts a mapped service without a specialist price link' do
      other_resource = create(:scheduling_resource, account: account)
      create(:scheduling_service_price, account: account, resource: other_resource, service: service)

      perform(
        client_first_name: 'Айжан',
        client_last_name: 'Касымова',
        client_phone: ['+7', '700', '000', '0001'].join,
        service_id: service.id
      )

      expect(appointment.reload.service_id).to eq(service.id)
    end

    it 'accepts only linked services when the specialist has explicit links' do
      linked_service = create(
        :scheduling_service,
        account: account,
        custom_attributes: { 'medelement_nomenclature_code' => 'service-2' }
      )
      create(:scheduling_service_price, account: account, resource: resource, service: linked_service)

      request = lambda do
        perform(
          client_first_name: 'Айжан',
          client_last_name: 'Касымова',
          client_phone: ['+7', '700', '000', '0001'].join,
          service_id: service.id
        )
      end

      expect(&request).to raise_error(Scheduling::Error) do |error|
        expect(error.code).to eq('MEDELEMENT_SERVICE_UNAVAILABLE')
      end

      perform(
        client_first_name: 'Айжан',
        client_last_name: 'Касымова',
        client_phone: ['+7', '700', '000', '0001'].join,
        service_id: linked_service.id
      )

      expect(appointment.reload.service_id).to eq(linked_service.id)
    end

    it 'fails closed at the mutation boundary when provider availability is unavailable' do
      original_starts_at = appointment.starts_at
      moved_starts_at = original_starts_at + 1.hour
      appointment.update!(
        service: nil,
        client_first_name: 'Айжан',
        client_last_name: 'Касымова',
        external_ref: 'medelement:reception:reception-1',
        custom_attributes: appointment.custom_attributes.except('service_ids', 'services', 'medelement_reception_code')
      )
      local_result = instance_double(Scheduling::AvailabilityService::Result, available?: true)
      local_service = instance_double(Scheduling::AvailabilityService, availability_result: local_result)
      allow(Scheduling::AvailabilityService).to receive(:new).and_return(local_service)
      provider_result = Integrations::Medelement::ResourceAvailabilityService::Result.new(
        status: 'unavailable',
        checked_at: Time.current,
        slots: [],
        reason: 'provider_unavailable'
      )
      provider_service = instance_double(Integrations::Medelement::ResourceAvailabilityService, perform: provider_result)
      expect(Integrations::Medelement::ResourceAvailabilityService).to receive(:new).with(
        hash_including(cabinet_code: 'cabinet-1', exclude_reception_code: 'reception-1')
      ).and_return(provider_service)

      expect do
        perform(
          starts_at: moved_starts_at,
          ends_at: appointment.ends_at + 1.hour,
          client_phone: '+77001234567'
        )
      end.to raise_error(Scheduling::Error) { |error| expect(error.code).to eq('MEDELEMENT_AVAILABILITY_UNVERIFIED') }

      expect(appointment.reload.starts_at).to eq(original_starts_at)
    end

    it 'revalidates Medelement availability when only the selected cabinet changes' do
      appointment.update!(
        service: nil,
        client_first_name: 'Айжан',
        client_last_name: 'Касымова',
        custom_attributes: appointment.custom_attributes.except('service_ids', 'services').merge(
          'medelement_reception_code' => 'reception-1',
          'medelement_cabinet_code' => 'cabinet-1'
        )
      )
      resource.update!(
        custom_attributes: resource.custom_attributes.merge(
          'medelement_cabinets' => [
            { 'companyCabinetCode' => 'cabinet-1' },
            { 'companyCabinetCode' => 'cabinet-2' }
          ]
        )
      )
      local_result = instance_double(Scheduling::AvailabilityService::Result, available?: true)
      allow(Scheduling::AvailabilityService).to receive(:new).and_return(
        instance_double(Scheduling::AvailabilityService, availability_result: local_result)
      )
      provider_result = Integrations::Medelement::ResourceAvailabilityService::Result.new(
        status: 'fresh', checked_at: Time.current, slots: [], reason: nil
      )
      expect(Integrations::Medelement::ResourceAvailabilityService).to receive(:new).with(
        hash_including(cabinet_code: 'cabinet-2', exclude_reception_code: 'reception-1')
      ).and_return(instance_double(Integrations::Medelement::ResourceAvailabilityService, perform: provider_result))

      expect do
        perform(
          custom_attributes: appointment.custom_attributes.merge('medelement_cabinet_code' => 'cabinet-2'),
          client_phone: '+77001234567'
        )
      end.to raise_error(Scheduling::Error) { |error| expect(error.code).to eq('APPOINTMENT_SLOT_UNAVAILABLE') }

      expect(appointment.reload.custom_attributes['medelement_cabinet_code']).to eq('cabinet-1')
    end

    it 'allows cancellation of a legacy incomplete appointment' do
      perform(status: 'cancelled')

      expect(appointment.reload.status).to eq('cancelled')
    end
  end

  it 'composes the display name from all structured patient name fields' do
    perform(
      client_first_name: 'Айжан',
      client_last_name: 'Касымова',
      client_middle_name: 'Ерлановна'
    )

    expect(appointment.reload).to have_attributes(
      client_first_name: 'Айжан',
      client_last_name: 'Касымова',
      client_middle_name: 'Ерлановна',
      client_name: 'Айжан Касымова Ерлановна'
    )
  end
end
