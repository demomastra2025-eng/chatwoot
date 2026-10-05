require 'rails_helper'

# Owner questions, answered as executable proofs:
#   1. Setting «Подтвержден» in OneLink changes nothing in MedElement, and the next MedElement sync keeps it.
#   2. With remove_reception_on_cancel on, cancelling in OneLink sends exactly one MedElement reception removal, and later
#      syncs keep the appointment cancelled.
#   3. With remove_reception_on_cancel off (the default), cancelling stays in OneLink: nothing reaches MedElement and sync
#      keeps the local cancellation until MedElement itself completes, removes or moves the reception.
# End-to-end proofs: each example walks one full owner scenario, so they are intentionally long.
# rubocop:disable RSpec/DescribeClass, RSpec/MultipleExpectations, Metrics/MethodLength
RSpec.describe 'MedElement boundary for local appointment statuses' do
  include ActiveJob::TestHelper
  include ActiveSupport::Testing::TimeHelpers

  let(:zone) { ActiveSupport::TimeZone['Asia/Almaty'] }
  let(:now) { zone.local(2026, 3, 20, 10, 0, 0) }
  let(:starts_at) { zone.local(2026, 3, 21, 9, 0, 0) }
  let(:ends_at) { zone.local(2026, 3, 21, 9, 20, 0) }
  let(:account) { create(:account).tap { |record| record.enable_features!('scheduling') } }
  let(:actor) { create(:user) }
  let(:hook_settings) { attributes_for(:integrations_hook, :medelement)[:settings].merge('write_enabled' => true) }
  let(:contact) do
    create(
      :contact,
      account: account,
      name: 'Test',
      last_name: 'Patient',
      phone_number: ['+7', '700', '000', '0001'].join,
      custom_attributes: { 'medelement_patient_code' => 'patient-1' }
    )
  end
  let(:resource) do
    create(
      :scheduling_resource,
      account: account,
      timezone: 'Asia/Almaty',
      compensation_type: 'fixed',
      compensation_value: 6_000,
      custom_attributes: {
        'medelement_specialist_code' => 'specialist-1',
        'medelement_cabinets' => [{ 'companyCabinetCode' => 'cabinet-1' }]
      }
    )
  end
  let(:client) { instance_double(Integrations::Medelement::Client) }
  # OneLink only writes MedElement-mapped services, so the synced appointment carries one.
  let(:mapped_service) do
    create(:scheduling_service, account: account, duration_min: 20, base_price: 20_000,
                                custom_attributes: { 'medelement_nomenclature_code' => 'service-1' })
  end

  before do
    schedule_service = instance_double(Integrations::Medelement::CronScheduleService, sync!: true)
    allow(Integrations::Medelement::CronScheduleService).to receive(:new).and_return(schedule_service)
    create(:account_user, account: account, user: actor)
    create(:integrations_hook, :medelement, account: account, settings: hook_settings)
    allow(Integrations::Medelement::Client).to receive(:new).and_return(client)
    travel_to(now)
    clear_enqueued_jobs
  end

  # A OneLink-created appointment that was already written to MedElement as reception-1.
  def synced_onelink_appointment(status: 'scheduled')
    appointment = create(
      :scheduling_appointment,
      account: account,
      contact: contact,
      resource: resource,
      service: mapped_service,
      duration_min: 20,
      source: 'manual',
      status: status,
      payment_status: 'awaiting_payment',
      starts_at: starts_at,
      ends_at: ends_at,
      client_first_name: 'Test',
      client_last_name: 'Patient',
      client_phone: contact.phone_number,
      external_ref: 'medelement:reception:reception-1',
      custom_attributes: {
        'medelement_reception_code' => 'reception-1',
        'medelement_cabinet_code' => 'cabinet-1',
        Integrations::Medelement::AppointmentProviderStatus::ATTRIBUTE_KEY => 'succeeded'
      }
    )
    Integrations::Medelement::ProviderCommand.create!(
      account: account, appointment: appointment, contact: contact, operation: 'create_reception', status: 'succeeded',
      idempotency_key: SecureRandom.uuid, company_cabinet_code: 'cabinet-1', desired_starts_at: starts_at,
      desired_ends_at: ends_at, provider_reception_code: 'reception-1', provider_patient_code: 'patient-1', executed_at: Time.current
    )
    clear_enqueued_jobs
    appointment
  end

  def imported_appointment(status: 'scheduled')
    create(
      :scheduling_appointment,
      account: account,
      contact: contact,
      resource: resource,
      source: 'medelement',
      status: status,
      starts_at: starts_at,
      ends_at: ends_at,
      external_ref: 'medelement:reception:reception-1',
      custom_attributes: { 'medelement_reception_code' => 'reception-1', 'medelement_cabinet_code' => 'cabinet-1' }
    ).tap { clear_enqueued_jobs }
  end

  def provider_time(value)
    value.in_time_zone('Asia/Almaty').strftime('%d.%m.%Y %H:%M:%S')
  end

  def listed_reception(active:, removed:, shift: 0)
    {
      'RECEPTION_CODE' => 'reception-1',
      'PATIENT_CODE' => 'patient-1',
      'STARTTIME' => (starts_at + shift).strftime('%Y-%m-%d %H:%M:%S'),
      'ENDTIME' => (ends_at + shift).strftime('%Y-%m-%d %H:%M:%S'),
      'ACTIVE' => active,
      'REMOVED' => removed,
      'COMPANY_CABINET_CODE' => 'cabinet-1'
    }
  end

  # The sync client is a strict double: any MedElement write method would raise because it is not stubbed.
  def run_reception_sync(listed)
    sync_client = instance_double(Integrations::Medelement::Client)
    allow(sync_client).to receive(:get_receptions).and_return(listed)
    allow(sync_client).to receive(:get_reception) do |reception_code:, **|
      listed.first.merge('RECEPTION_CODE' => reception_code, 'PROFILE_CODE' => 'patient-1', 'COMPANY_CODE' => 'company-1',
                         'SERVICES' => [])
    end
    configuration = instance_double(
      Integrations::Medelement::Configuration,
      sync_patients?: false, receptions_days_back: 3, receptions_days_forward: 70, reception_detail_budget: 50,
      reception_detail_refresh_interval: 6.hours, throttle_ms: 0, time_zone: 'Asia/Almaty', organization_id: 'company-1'
    )
    Integrations::Medelement::ReceptionsSyncService.new(
      account: account, client: sync_client, configuration: configuration,
      conflict_tracker: instance_double(Integrations::Medelement::ConflictTracker, record!: true)
    ).perform
  end

  describe 'confirming an appointment' do
    it 'has no MedElement API that could write an appointment status' do
      provider_methods = Integrations::Medelement::Client.public_instance_methods(false).map(&:to_s)

      expect(provider_methods.grep(/status|confirm/)).to be_empty
      expect(provider_methods.grep(/\A(create|update|move|remove|change|set)_/)).to contain_exactly(
        'create_patient', 'update_patient', 'create_reception', 'move_reception', 'remove_reception'
      )
    end

    [%w[scheduled confirmed], %w[confirmed scheduled]].each do |from, to|
      it "keeps a #{from} -> #{to} change of a MedElement-linked appointment inside OneLink" do
        appointment = synced_onelink_appointment(status: from)
        commands_before = Integrations::Medelement::ProviderCommand.count

        result = Scheduling::Appointments::UpsertService.new(
          account: account, appointment: appointment, params: { status: to }, actor: actor
        ).perform

        expect(result.reload.status).to eq(to)
        expect(result.custom_attributes[Integrations::Medelement::AppointmentProviderStatus::ATTRIBUTE_KEY]).to eq('succeeded')
        expect(result.medelement_provider_command_receipt).to be_nil
        expect(Integrations::Medelement::ProviderCommand.count).to eq(commands_before)
        expect(ConfirmationRequest.where(account: account)).to be_empty
        expect(Integrations::Medelement::OutboundChangeJob).not_to have_been_enqueued
        expect(Integrations::Medelement::ProviderCommandConfirmationJob).not_to have_been_enqueued
        expect(Integrations::Medelement::ProviderCommandJob).not_to have_been_enqueued
        expect(Integrations::Medelement::Client).not_to have_received(:new)
        expect(a_request(:any, /medelement/)).not_to have_been_made
      end
    end

    {
      'OneLink-created' => :synced_onelink_appointment,
      'imported (patient reply path)' => :imported_appointment
    }.each do |kind, factory_method|
      it "does not create a provider command when the async outbound listener sees a #{kind} confirmation" do
        appointment = send(factory_method)
        commands_before = Integrations::Medelement::ProviderCommand.count
        begin
          Current.executed_by = actor
          appointment.update!(status: 'confirmed')
        ensure
          Current.reset
        end
        event = Events::Base.new(
          'appointment_updated', Time.current,
          appointment: appointment, performed_by: actor, changed_attributes: { 'status' => %w[scheduled confirmed] },
          medelement_source_updated_at: appointment.updated_at.utc.iso8601(6),
          medelement_outbound_snapshot: Integrations::Medelement::OutboundChangeService.appointment_event_snapshot(appointment)
        )
        clear_enqueued_jobs

        MedelementOutboundChangeListener.instance.appointment_updated(event)

        expect(appointment.medelement_provider_command_receipt).to be_nil
        expect(Integrations::Medelement::ProviderCommand.count).to eq(commands_before)
        expect(Integrations::Medelement::OutboundChangeJob).not_to have_been_enqueued
        expect(Integrations::Medelement::Client).not_to have_received(:new)
      end
    end

    it 'keeps staff edits of an appointment imported from MedElement read-only' do
      appointment = imported_appointment

      expect do
        Scheduling::Appointments::UpsertService.new(
          account: account, appointment: appointment, params: { status: 'confirmed' }, actor: actor
        ).perform
      end.to raise_error(Scheduling::Error) { |error| expect(error.code).to eq('APPOINTMENT_READ_ONLY') }
      expect(appointment.reload.status).to eq('scheduled')
    end

    it 'keeps a local confirmation when a later sync sees the reception still active in MedElement' do
      onelink_created = synced_onelink_appointment(status: 'confirmed')
      commands_before = Integrations::Medelement::ProviderCommand.count

      result = run_reception_sync([listed_reception(active: 1, removed: 0)])

      expect(result).to include(imported_count: 1)
      expect(onelink_created.reload.status).to eq('confirmed')
      expect(onelink_created.source).to eq('manual')
      expect(onelink_created.custom_attributes['provider_status_audit']).to include(
        'source' => 'medelement_reception_sync', 'previous_status' => 'confirmed', 'status' => 'confirmed',
        'reason' => 'preserved_local_confirmation'
      )
      expect(Integrations::Medelement::ProviderCommand.count).to eq(commands_before)
    end

    it 'keeps a patient-confirmed imported appointment confirmed across repeated syncs' do
      imported = imported_appointment(status: 'confirmed')

      run_reception_sync([listed_reception(active: 1, removed: 0)])
      travel 7.hours
      run_reception_sync([listed_reception(active: 1, removed: 0)])

      expect(imported.reload).to have_attributes(status: 'confirmed', source: 'medelement')
      expect(imported.custom_attributes.dig('provider_status_audit', 'reason')).to eq('preserved_local_confirmation')
      expect(Integrations::Medelement::ProviderCommand.where(appointment: imported)).to be_empty
    end
  end

  describe 'cancelling an appointment with remove_reception_on_cancel on (removal flow, unchanged)' do
    let(:hook_settings) { super().merge('remove_reception_on_cancel' => true) }
    let(:active_reception) do
      {
        'RECEPTION_CODE' => 'reception-1',
        'PROFILE_CODE' => 'patient-1',
        'SPECIALIST_CODE' => 'specialist-1',
        'STARTTIME' => provider_time(starts_at),
        'ENDTIME' => provider_time(ends_at),
        'ACTIVE' => 1,
        'REMOVED' => 0,
        'SERVICES' => [{ 'NOMENCLATURE_CODE' => 'service-1' }]
      }
    end

    def stub_provider_reception(paid: 'not')
      allow(client).to receive(:get_reception).with(reception_code: 'reception-1').and_return(active_reception)
      allow(client).to receive(:get_reception).with(reception_code: 'reception-1', version: :v1).and_return(
        active_reception.slice('RECEPTION_CODE', 'PROFILE_CODE', 'STARTTIME', 'ENDTIME', 'SERVICES').merge('REMOVED' => 1)
      )
      allow(client).to receive(:get_receptions).and_return(
        [{ 'RECEPTION_CODE' => 'reception-1', 'COMPANY_CABINET_CODE' => 'cabinet-1', 'PAID' => paid }]
      )
      allow(client).to receive(:remove_reception).and_return({})
    end

    def cancel_and_execute(appointment)
      result = Scheduling::Appointments::CancelService.new(appointment: appointment, actor: actor).perform
      command = result.medelement_provider_command_receipt
      Integrations::Medelement::ProviderCommandConfirmationJob.perform_now(command.confirmation_request_id)
      Integrations::Medelement::ProviderCommands::Executor.new(command: command.reload).perform
      [result, command.reload]
    end

    it 'sends one MedElement removal for a confirmed appointment and keeps it cancelled across later syncs' do
      appointment = synced_onelink_appointment(status: 'confirmed')
      stub_provider_reception

      result, command = cancel_and_execute(appointment)

      expect(result).to have_attributes(status: 'confirmed')
      expect(command).to have_attributes(operation: 'remove_reception', provider_reception_code: 'reception-1',
                                         requested_by_id: actor.id)
      expect(command).to be_succeeded, "status=#{command.status} error=#{command.last_error_code}"
      expect(client).to have_received(:remove_reception).with(reception_code: 'reception-1').once
      expect(appointment.reload).to have_attributes(status: 'cancelled', payment_status: 'cancelled')
      expect(appointment.custom_attributes).to include(
        Integrations::Medelement::AppointmentProviderStatus::ATTRIBUTE_KEY => 'succeeded',
        Integrations::Medelement::AppointmentProviderStatus::CANCELLATION_COMMAND_ID_KEY => command.id
      )

      Integrations::Medelement::ProviderCommands::Executor.new(command: command).perform
      Scheduling::Appointments::CancelService.new(appointment: appointment.reload, actor: actor).perform
      expect(client).to have_received(:remove_reception).once
      commands_after_cancel = Integrations::Medelement::ProviderCommand.count

      run_reception_sync([listed_reception(active: 0, removed: 1)])
      run_reception_sync([])
      travel 7.hours
      run_reception_sync([])

      expect(appointment.reload).to have_attributes(status: 'cancelled', payment_status: 'cancelled', source: 'manual')
      expect(appointment.custom_attributes['source_mode']).not_to eq('provider_tombstone')
      expect(appointment.custom_attributes).not_to include('medelement_missing_syncs')
      expect(Integrations::Medelement::ProviderCommand.count).to eq(commands_after_cancel)
    end

    it 'refuses to remove a paid MedElement reception and leaves the OneLink appointment active for review' do
      appointment = synced_onelink_appointment(status: 'confirmed')
      stub_provider_reception(paid: 'full')

      _result, command = cancel_and_execute(appointment)

      expect(command).to have_attributes(status: 'failed', last_error_code: 'remote_state_changed')
      expect(client).not_to have_received(:remove_reception)
      expect(appointment.reload.status).to eq('confirmed')
      expect(appointment.custom_attributes).to include(
        Integrations::Medelement::AppointmentProviderStatus::ATTRIBUTE_KEY => 'failed',
        Integrations::Medelement::AppointmentProviderStatus::CANCELLATION_COMMAND_ID_KEY => command.id
      )

      run_reception_sync([listed_reception(active: 1, removed: 0)])

      expect(appointment.reload.status).to eq('confirmed')
    end
  end

  # Owner decision 01.10.2026: «пока что не удалять в МедЭлементе; пусть тут отменяют, а туда не уходит».
  describe 'cancelling an appointment with remove_reception_on_cancel off (default)' do
    let(:marker_key) { Integrations::Medelement::LocalCancellation::MARKER_KEY }

    def cancel_locally(appointment)
      Scheduling::Appointments::CancelService.new(appointment: appointment, actor: actor).perform
    end

    def prepare_paid_appointment!(appointment)
      appointment.update!(
        service_amount: 20_000,
        payment_status: 'paid',
        settlement_amount: 20_000,
        settlement_payment_method: 'cash',
        compensation_type_snapshot: 'fixed',
        compensation_value_snapshot: 6_000,
        compensation_percent_snapshot: 0
      )
      create(
        :scheduling_payment,
        account: appointment.account,
        appointment: appointment,
        amount: 20_000,
        payment_method: 'cash',
        payment_kind: 'adjustment',
        recorded_by: actor
      )
      Scheduling::Appointments::FinanceSyncService.new(appointment: appointment, actor: actor).sync!
      appointment.reload
    end

    def expect_no_provider_traffic(commands_before)
      expect_no_provider_commands(commands_before)
      expect_no_provider_jobs
      expect_no_provider_requests
    end

    def expect_no_provider_commands(commands_before)
      expect(Integrations::Medelement::ProviderCommand.count).to eq(commands_before)
      expect(Integrations::Medelement::ProviderCommand.where(operation: 'remove_reception')).to be_empty
      expect(ConfirmationRequest.where(account: account)).to be_empty
    end

    def expect_no_provider_jobs
      expect(Integrations::Medelement::OutboundChangeJob).not_to have_been_enqueued
      expect(Integrations::Medelement::ProviderCommandConfirmationJob).not_to have_been_enqueued
      expect(Integrations::Medelement::ProviderCommandJob).not_to have_been_enqueued
    end

    def expect_no_provider_requests
      expect(Integrations::Medelement::Client).not_to have_received(:new)
      expect(a_request(:any, /medelement/)).not_to have_been_made
    end

    it 'defaults to keeping MedElement receptions and persists the toggle in the hook settings' do
      hook = account.hooks.find_by!(app_id: 'medelement')

      expect(hook.settings).not_to have_key('remove_reception_on_cancel')
      expect(Integrations::Medelement::Configuration.new(hook: hook).remove_reception_on_cancel?).to be(false)

      hook.update!(settings: hook.settings.merge('remove_reception_on_cancel' => true))
      expect(Integrations::Medelement::Configuration.new(hook: hook.reload).remove_reception_on_cancel?).to be(true)

      hook.update!(settings: hook.settings.merge('remove_reception_on_cancel' => false))
      expect(Integrations::Medelement::Configuration.new(hook: hook.reload).remove_reception_on_cancel?).to be(false)
    end

    {
      'OneLink-created' => :synced_onelink_appointment,
      'imported' => :imported_appointment
    }.each do |kind, factory_method|
      it "cancels a #{kind} appointment only in OneLink and records that the reception is still alive" do
        appointment = send(factory_method, status: 'confirmed')
        commands_before = Integrations::Medelement::ProviderCommand.count

        result = cancel_locally(appointment)

        expect(result).to have_attributes(status: 'cancelled', payment_status: 'cancelled')
        expect(result.medelement_provider_command_receipt).to be_nil
        expect(result.custom_attributes[marker_key]).to include(
          'reception_code' => 'reception-1', 'provider_starts_at' => starts_at.utc.iso8601,
          'previous_status' => 'confirmed', 'actor' => { 'type' => 'User', 'id' => actor.id }
        )
        expect(result.custom_attributes).not_to have_key(Integrations::Medelement::AppointmentSnapshotGuard::LOCAL_CANCELLATION_ATTRIBUTE)
        expect_no_provider_traffic(commands_before)
      end
    end

    it 'never turns the cancellation event into a removal, whichever outbound path sees it' do
      appointment = synced_onelink_appointment
      cancel_locally(appointment)
      commands_before = Integrations::Medelement::ProviderCommand.count
      event = Events::Base.new(
        'appointment_cancelled', Time.current,
        appointment: appointment.reload, performed_by: actor, changed_attributes: { 'status' => %w[scheduled cancelled] },
        medelement_source_updated_at: appointment.updated_at.utc.iso8601(6),
        medelement_outbound_snapshot: Integrations::Medelement::OutboundChangeService.appointment_event_snapshot(appointment)
      )

      MedelementOutboundChangeListener.instance.appointment_cancelled(event)
      direct = Integrations::Medelement::OutboundChangeService.new(
        entity_type: 'appointment', entity_id: appointment.id, event_name: 'appointment_cancelled', account_id: account.id,
        actor_id: actor.id, change: { desired_attributes: Integrations::Medelement::OutboundChangeService.appointment_event_snapshot(appointment) }
      ).perform

      expect(direct).to be_nil
      expect_no_provider_traffic(commands_before)
    end

    it 'follows the same local path for a generic status change to cancelled' do
      appointment = synced_onelink_appointment
      commands_before = Integrations::Medelement::ProviderCommand.count

      result = Scheduling::Appointments::UpsertService.new(
        account: account, appointment: appointment, params: { status: 'cancelled' }, actor: actor
      ).perform

      expect(result.reload).to have_attributes(status: 'cancelled', payment_status: 'cancelled')
      expect(result.custom_attributes[marker_key]).to be_present
      expect_no_provider_traffic(commands_before)
    end

    it 'refuses to queue a MedElement reception removal while the toggle is off' do
      appointment = synced_onelink_appointment
      validator = Integrations::Medelement::ProviderCommands::Validator.new(
        account: account, hook: account.hooks.find_by!(app_id: 'medelement'), appointment: appointment, contact: contact,
        operation: 'remove_reception', idempotency_key: 'remove-1', company_cabinet_code: nil
      )

      expect { validator.validate_runtime! }.to raise_error(Scheduling::Error) { |error| expect(error.code).to eq('MEDELEMENT_REMOVAL_DISABLED') }
    end

    it 'keeps the local cancellation across syncs while MedElement still shows the reception active' do
      appointment = synced_onelink_appointment
      cancel_locally(appointment)
      commands_before = Integrations::Medelement::ProviderCommand.count

      run_reception_sync([listed_reception(active: 1, removed: 0)])
      travel 7.hours
      run_reception_sync([listed_reception(active: 1, removed: 0)])

      expect(appointment.reload).to have_attributes(status: 'cancelled', payment_status: 'cancelled', source: 'manual')
      expect(appointment.custom_attributes[marker_key]).to be_present
      expect(appointment.custom_attributes['provider_status_audit']).to include(
        'previous_status' => 'cancelled', 'status' => 'cancelled', 'reason' => 'preserved_local_cancellation'
      )
      expect(Integrations::Medelement::ProviderCommand.count).to eq(commands_before)
    end

    it 'keeps an imported appointment cancelled across syncs and does not flap its status' do
      appointment = imported_appointment
      cancel_locally(appointment)

      run_reception_sync([listed_reception(active: 1, removed: 0)])
      travel 7.hours
      run_reception_sync([listed_reception(active: 1, removed: 0)])

      expect(appointment.reload).to have_attributes(status: 'cancelled', source: 'medelement')
      expect(appointment.custom_attributes[marker_key]).to be_present
    end

    it 'restores the unpaid expense when MedElement completes a paid local cancellation' do
      appointment = synced_onelink_appointment
      prepare_paid_appointment!(appointment)
      cancel_locally(appointment)

      expect(appointment.reload.expense).to be_nil
      run_reception_sync([listed_reception(active: 0, removed: 0)])

      expect(appointment.reload).to have_attributes(status: 'completed', payment_status: 'paid')
      expect(appointment.expense).to have_attributes(status: 'unpaid', amount: 6_000)
      expect(appointment.custom_attributes).not_to have_key(marker_key)
      expect(appointment.custom_attributes.dig('provider_status_audit', 'reason')).to eq('provider_inactive')
    end

    it 'lets MedElement win when the reception is removed there' do
      appointment = synced_onelink_appointment
      cancel_locally(appointment)

      run_reception_sync([listed_reception(active: 0, removed: 1)])
      run_reception_sync([listed_reception(active: 0, removed: 1)])

      expect(appointment.reload).to have_attributes(status: 'cancelled', payment_status: 'cancelled')
      expect(appointment.custom_attributes).not_to have_key(marker_key)
      expect(appointment.custom_attributes['source_mode']).to eq('provider_tombstone')
    end

    it 'treats a reception moved to another time in MedElement as re-booked' do
      appointment = synced_onelink_appointment
      cancel_locally(appointment)

      run_reception_sync([listed_reception(active: 1, removed: 0, shift: 1.hour)])

      expect(appointment.reload).to have_attributes(status: 'scheduled', payment_status: 'awaiting_payment',
                                                    starts_at: starts_at + 1.hour)
      expect(appointment.custom_attributes).not_to have_key(marker_key)
      expect(appointment.custom_attributes.dig('provider_status_audit', 'reason')).to eq('provider_rebooked_after_local_cancellation')
    end

    it 'restores the unpaid expense when MedElement re-books a paid locally-cancelled appointment' do
      appointment = synced_onelink_appointment
      prepare_paid_appointment!(appointment)
      adjustment_payment_id = appointment.payments.find_by!(payment_kind: 'adjustment').id
      cancel_locally(appointment)

      expect(appointment.reload.expense).to be_nil
      run_reception_sync([listed_reception(active: 1, removed: 0, shift: 1.hour)])

      expect(appointment.reload).to have_attributes(status: 'scheduled', payment_status: 'paid')
      expect(appointment.expense).to have_attributes(status: 'unpaid', amount: 6_000)
      expect(appointment.payments.find_by!(payment_kind: 'adjustment')).to have_attributes(
        id: adjustment_payment_id, recorded_by_id: actor.id
      )

      run_reception_sync([listed_reception(active: 1, removed: 0, shift: 1.hour)])
      expect(appointment.reload.expense).to have_attributes(status: 'unpaid', amount: 6_000)
      expect(Scheduling::Expense.where(appointment: appointment).count).to eq(1)
    end

    it 'restores payment state and expense when staff manually reopens a local cancellation' do
      appointment = synced_onelink_appointment
      prepare_paid_appointment!(appointment)
      cancel_locally(appointment)

      service = Scheduling::Appointments::UpsertService.new(
        account: account, appointment: appointment, params: { status: 'scheduled' }, actor: actor
      )
      # Reopening only exercises payment and expense restoration; this fixture has no working-hours rules.
      allow(service).to receive(:validate_availability!)

      result = service.perform

      expect(result.reload).to have_attributes(status: 'scheduled', payment_status: 'paid')
      expect(result.custom_attributes).not_to have_key(marker_key)
      expect(result.expense).to have_attributes(status: 'unpaid', amount: 6_000)
    end

    it 'uses only this account integration toggle when cancelling a linked appointment' do
      other_account = create(:account).tap { |record| record.enable_features!('scheduling') }
      create(
        :integrations_hook,
        :medelement,
        account: other_account,
        settings: hook_settings.merge('remove_reception_on_cancel' => true)
      )
      appointment = synced_onelink_appointment
      commands_before = Integrations::Medelement::ProviderCommand.count

      result = cancel_locally(appointment)

      expect(result.reload.status).to eq('cancelled')
      expect(result.custom_attributes[marker_key]).to be_present
      expect_no_provider_traffic(commands_before)
    end

    it 'records a local cancellation even when a provider-linked appointment has no reception code' do
      appointment = synced_onelink_appointment
      appointment.update!(
        external_ref: nil,
        custom_attributes: appointment.custom_attributes.except('medelement_reception_code')
      )

      result = cancel_locally(appointment)

      expect(result.reload.status).to eq('cancelled')
      expect(result.custom_attributes[marker_key]).to be_present
      expect(result.custom_attributes[marker_key]).not_to have_key('reception_code')
    end

    it 'keeps the locally cancelled record from being deleted so the next sync cannot import it again' do
      appointment = synced_onelink_appointment
      cancel_locally(appointment)

      expect do
        Scheduling::Appointments::ProviderCancellationPolicy.new(appointment: appointment.reload).ensure_deletable!
      end.to raise_error(Scheduling::Error) { |error| expect(error.code).to eq('MEDELEMENT_LOCAL_CANCELLATION_PROTECTED') }
    end

    it 'tells the UI which cancellation mode applies' do
      appointment = synced_onelink_appointment

      expect(Scheduling::PayloadBuilder.appointment(appointment)[:medelement_cancellation_mode]).to eq('local_only')
      hook = account.hooks.find_by!(app_id: 'medelement')
      hook.update!(settings: hook.settings.merge('remove_reception_on_cancel' => true))
      expect(Scheduling::PayloadBuilder.appointments([appointment]).first[:medelement_cancellation_mode]).to eq('provider_removal')
    end
  end
end
# rubocop:enable RSpec/DescribeClass, RSpec/MultipleExpectations, Metrics/MethodLength
