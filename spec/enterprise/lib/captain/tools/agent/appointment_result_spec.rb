require 'rails_helper'

RSpec.describe Captain::Tools::Agent::AppointmentResult do
  it 'preserves booking success and warns against recreating it when optional CRM linkage needs attention' do
    warning = { 'status' => 'not_linked', 'code' => 'CRM_REQUIRED_FIELDS', 'message' => 'Required field is missing' }
    appointment = create(:scheduling_appointment, custom_attributes: { 'crm_link_result' => warning })

    result = described_class.success(appointment, action: 'create_appointment')

    expect(result).to include(success: true, appointment_id: appointment.id, crm_link_result: warning)
    expect(result[:crm_link_guidance]).to include('Do not create it again')
  end

  it 'does not report an asynchronous provider move or removal as completed' do
    appointment = create(:scheduling_appointment, custom_attributes: { 'medelement_provider_sync_status' => 'pending' })
    %w[update_appointment cancel_appointment].each do |action|
      result = described_class.success(appointment, action: action)
      expect(result).to include(
        success: false, reason: 'pending_provider_confirmation', status: 'pending_provider_confirmation', provider_confirmed: false
      )
      expect(Captain::ToolResult.normalize(result.to_json)).to include(success: false, retryable: false)
    end
  end

  it 'makes a local-only cancellation explicit and preserves the provider reception' do
    appointment = create(:scheduling_appointment, status: 'cancelled', custom_attributes: {
                           'medelement_provider_sync_status' => 'succeeded', 'medelement_local_cancellation' => { 'at' => Time.current.iso8601 }
                         })
    appointment.medelement_provider_command_receipt = instance_double(
      Integrations::Medelement::ProviderCommand, operation: 'move_reception', succeeded?: true
    )
    expect(described_class.success(appointment, action: 'cancel_appointment')).to include(
      success: true, status: 'cancelled_local_only', cancellation_scope: 'onelink_only', provider_reception_active: true,
      provider_confirmed: false, provider_confirmation_operation: 'remove_reception', provider_confirmation_scope: 'onelink'
    )
    expect(described_class.appointment(appointment)).to include(
      provider_confirmed: false, provider_confirmation_operation: 'remove_reception', provider_confirmation_scope: 'onelink'
    )
  end

  it 'uses the exact queued command receipt instead of an older successful appointment status' do
    appointment = create(:scheduling_appointment, source: 'medelement', custom_attributes: { 'medelement_provider_sync_status' => 'succeeded' })
    appointment.medelement_provider_command_receipt = instance_double(
      Integrations::Medelement::ProviderCommand, operation: 'move_reception', succeeded?: false, provider_status_unknown?: false, terminal?: false
    )
    expect(described_class.success(appointment, action: 'update_appointment')).to include(
      success: false, status: 'pending_provider_confirmation', reason: 'pending_provider_confirmation', provider_confirmed: false
    )
    expect(appointment.custom_attributes['medelement_provider_sync_status']).to eq('succeeded')
  end

  it 'does not turn a failed exact receipt into success after an earlier provider operation' do
    appointment = create(:scheduling_appointment, custom_attributes: { 'medelement_provider_sync_status' => 'succeeded' })
    appointment.medelement_provider_command_receipt = instance_double(
      Integrations::Medelement::ProviderCommand, operation: 'remove_reception', succeeded?: false, provider_status_unknown?: false, terminal?: true
    )
    expect(described_class.success(appointment, action: 'cancel_appointment')).to include(
      success: false, status: 'provider_confirmation_failed', reason: 'staff_will_help', provider_confirmed: false
    )
  end

  described_class::PROVIDER_OPERATIONS.each do |action, operation|
    it "reports the exact #{operation} confirmation in mutations and search/get results" do
      provider = Integrations::Medelement::AppointmentProviderStatus
      receipt = instance_double(
        Integrations::Medelement::ProviderCommand, id: 81, operation: operation, succeeded?: true,
        idempotency_key: 'exact-request', execution_state: { 'request_fingerprint' => 'fp', 'dispatch_identity' => 'dispatch' },
        remove_reception?: operation == 'remove_reception'
      )
      attributes = provider.command_attributes(receipt).merge(provider::ATTRIBUTE_KEY => provider::SUCCEEDED)
      appointment = create(:scheduling_appointment, status: operation == 'remove_reception' ? 'cancelled' : 'scheduled',
                                                   custom_attributes: attributes)
      appointment.medelement_provider_command_receipt = receipt

      expected = { provider_confirmed: true, provider_confirmation_status: 'succeeded',
                   provider_confirmation_operation: operation, provider_confirmation_scope: 'medelement' }
      expect(described_class.success(appointment, action: action)).to include(expected.merge(success: true))
      expect(described_class.appointment(appointment)).to include(expected)
      expect(described_class.success(appointment)).to include(expected.merge(success: true))
    end
  end

  it 'does not let a successful move receipt confirm an unmarked cancellation' do
    appointment = create(:scheduling_appointment, status: 'cancelled', source: 'medelement', custom_attributes: {
                           'medelement_provider_sync_status' => 'succeeded', 'medelement_provider_operation' => 'move_reception',
                           'medelement_provider_command_id' => 81
                         })
    appointment.medelement_provider_command_receipt = instance_double(
      Integrations::Medelement::ProviderCommand, operation: 'move_reception', succeeded?: true
    )
    expect(described_class.success(appointment, action: 'cancel_appointment')).to include(
      success: false, provider_confirmed: false, provider_confirmation_operation: 'remove_reception',
      provider_confirmation_scope: 'medelement', provider_confirmation_status: 'not_confirmed'
    )
  end

  it 'does not treat a successful receipt without current command binding as confirmation' do
    appointment = create(:scheduling_appointment, custom_attributes: {
                           'medelement_provider_sync_status' => 'succeeded', 'medelement_provider_operation' => 'move_reception'
                         })
    appointment.medelement_provider_command_receipt = instance_double(
      Integrations::Medelement::ProviderCommand, operation: 'move_reception', succeeded?: true
    )
    result = described_class.success(appointment, action: 'update_appointment')
    expect(result).to include(
      success: false, provider_confirmed: false, provider_confirmation_operation: 'move_reception',
      provider_confirmation_status: 'not_confirmed', provider_confirmation_scope: 'medelement'
    )
    expect(Captain::ToolResult.normalize(result.to_json)).to include(success: false, retryable: false)
  end

  it 'keeps an exact bound legacy create receipt successful without guessing from a status alone' do
    provider = Integrations::Medelement::AppointmentProviderStatus
    receipt = instance_double(
      Integrations::Medelement::ProviderCommand, id: 81, operation: 'create_reception', succeeded?: true,
      idempotency_key: 'legacy-exact-request', execution_state: { 'request_fingerprint' => 'fp', 'dispatch_identity' => 'dispatch' },
      remove_reception?: false
    )
    attributes = provider.command_attributes(receipt).except(provider::OPERATION_KEY).merge(provider::ATTRIBUTE_KEY => provider::SUCCEEDED)
    appointment = create(:scheduling_appointment, custom_attributes: attributes)
    appointment.medelement_provider_command_receipt = receipt

    expect(described_class.success(appointment, action: 'create_appointment')).to include(
      success: true, provider_confirmed: true, provider_confirmation_operation: 'create_reception', provider_confirmation_scope: 'medelement'
    )
  end

  it 'does not label a local comment edit as a newly confirmed provider move' do
    appointment = create(:scheduling_appointment, custom_attributes: {
                           'medelement_provider_sync_status' => 'succeeded', 'medelement_provider_operation' => 'create_reception'
                         })
    expect(described_class.success(appointment, action: 'update_appointment')).to include(
      success: true, provider_confirmed: false, provider_confirmation_operation: 'move_reception',
      provider_confirmation_status: 'not_requested', provider_confirmation_scope: 'medelement'
    )
  end

  describe 'a reschedule MedElement has not confirmed' do
    let(:account) { create(:account) }
    let(:resource) { create(:scheduling_resource, account: account, timezone: 'Asia/Almaty') }

    def unconfirmed_move(state:, sync_status:, error: {})
      entry = {
        'state' => state, 'command_id' => 160,
        'confirmed_starts_at' => '2026-10-15T05:00:00.000000Z', 'confirmed_ends_at' => '2026-10-15T05:30:00.000000Z',
        'requested_starts_at' => '2026-10-14T05:30:00.000000Z', 'requested_ends_at' => '2026-10-14T06:00:00.000000Z'
      }.merge(error)
      create(:scheduling_appointment, account: account, resource: resource, starts_at: Time.utc(2026, 10, 15, 5, 0),
                                      ends_at: Time.utc(2026, 10, 15, 5, 30),
                                      custom_attributes: { 'medelement_provider_sync_status' => sync_status,
                                                           'medelement_provider_operation' => 'move_reception',
                                                           'medelement_move_request' => entry })
    end

    # A rejection proven by read-back leaves the reception provider-confirmed (succeeded) at its previous time.
    [
      %w[pending pending], %w[needs_reconciliation provider_status_unknown], %w[rejected failed], %w[rejected succeeded]
    ].each do |state, sync_status|
      it "reports the confirmed time and never the requested one as the appointment time while the move is #{state} (#{sync_status})" do
        appointment = unconfirmed_move(state: state, sync_status: sync_status)

        [described_class.success(appointment, action: 'update_appointment'), described_class.appointment(appointment)].each do |result|
          expect(result).to include(
            local_date: '15.10.2026', local_time: '10:00', requested_local_date: '14.10.2026', requested_local_time: '10:30',
            move_state: state
          )
          expect(result[:move_guidance]).to include('Do not tell the patient it was moved')
        end
        expect(described_class.success(appointment, action: 'update_appointment')).to include(provider_confirmed: false)
        expect(described_class.appointment(appointment)).to include(provider_confirmed: false) unless sync_status == 'succeeded'
      end

      it "does not claim the move succeeded when it is #{state} (#{sync_status})" do
        result = described_class.success(unconfirmed_move(state: state, sync_status: sync_status), action: 'update_appointment')

        expect(result).to include(success: false, provider_confirmed: false)
        expect(result[:status]).not_to eq('updated')
        expect(Captain::ToolResult.normalize(result.to_json)).to include(success: false, retryable: false)
      end
    end

    it 'reports a rejection proven by read-back as a failed update even though the reception is provider-confirmed' do
      appointment = unconfirmed_move(state: 'rejected', sync_status: 'succeeded', error: { 'evidence' => 'provider_rejected' })

      expect(described_class.appointment(appointment)).to include(provider_confirmed: true, move_state: 'rejected')
      expect(described_class.success(appointment, action: 'update_appointment')).to include(
        success: false, status: 'provider_confirmation_failed', reason: 'staff_will_help', provider_confirmation_status: 'failed',
        provider_confirmed: false
      )
    end

    it 'keeps a failed move out of the success status even after the provider rejection' do
      appointment = unconfirmed_move(state: 'rejected', sync_status: 'failed',
                                     error: { 'error_code' => 'provider_http_error', 'error_status' => 400 })

      expect(described_class.success(appointment, action: 'update_appointment')).to include(
        success: false, status: 'provider_confirmation_failed', reason: 'staff_will_help', provider_confirmation_status: 'failed'
      )
    end

    it 'adds no move fields to an appointment without a pending or rejected reschedule' do
      expect(described_class.appointment(create(:scheduling_appointment, account: account, resource: resource)).keys)
        .not_to include(:move_state, :requested_local_date, :requested_local_time, :move_guidance)
    end
  end

  it 'maps only verified slot conflicts to time_taken' do
    conflict = Scheduling::Error.new(code: 'APPOINTMENT_SLOT_UNAVAILABLE', message: 'Unavailable', status: :conflict)
    unknown = Scheduling::Error.new(code: 'MEDELEMENT_AVAILABILITY_UNVERIFIED', message: 'Unknown', status: :service_unavailable)

    expect(described_class.failure(conflict)).to eq(success: false, reason: 'time_taken', error_class: 'business')
    expect(described_class.failure(unknown)).to eq(success: false, reason: 'staff_will_help', error_class: 'technical')
  end

  it 'maps the provider horizon and includes only the last bookable date' do
    error = Scheduling::Error.new(
      code: 'MEDELEMENT_HORIZON_EXCEEDED', message: 'Do not expose this text', status: :unprocessable_content,
      details: { last_available_date: '2026-10-15', provider_code: 'internal' }
    )

    expect(described_class.failure(error)).to eq(success: false, reason: 'schedule_not_open', last_available_date: '2026-10-15',
                                                 error_class: 'business')
  end

  it 'maps the unknown, failed, timed-out and superseded provider outcomes to a technical staff_will_help failure' do
    %w[MEDELEMENT_BOOKING_UNKNOWN MEDELEMENT_BOOKING_FAILED MEDELEMENT_BOOKING_SUPERSEDED MEDELEMENT_WRITE_FAILED MEDELEMENT_WRITE_UNKNOWN
       MEDELEMENT_WRITE_TIMEOUT MEDELEMENT_COMMAND_RECEIPT_UNAVAILABLE].each do |code|
      error = Scheduling::Error.new(code: code, message: 'Provider details', status: :unprocessable_content)
      expect(described_class.failure(error)).to eq(success: false, reason: 'staff_will_help', error_class: 'technical')
    end
  end

  it 'classes every failure as business or technical, with a stable machine flag' do
    business = [
      Scheduling::Error.new(code: 'SLOT_CONFLICT', message: 'x', status: :conflict),
      Scheduling::Error.new(code: 'VALIDATION_ERROR', message: 'x', status: :unprocessable_content),
      Scheduling::Error.new(code: 'APPOINTMENT_NOT_FOUND', message: 'x', status: :not_found),
      ArgumentError.new('Record is not available'),
      Scheduling::Error.new(code: 'INVALID_DATE', message: 'x', status: :unprocessable_content)
    ]
    technical = [
      Scheduling::Error.new(code: 'MEDELEMENT_WRITE_FAILED', message: 'x', status: :unprocessable_content),
      Scheduling::Error.new(code: 'PROVIDER_UNAVAILABLE', message: 'x', status: :service_unavailable),
      Scheduling::Error.new(code: 'INTERNAL_FAILURE', message: 'x', status: :internal_server_error),
      StandardError.new('boom')
    ]

    expect(business.map { |error| described_class.failure(error)[:error_class] }).to all(eq('business'))
    expect(technical.map { |error| described_class.failure(error)[:error_class] }).to all(eq('technical'))
  end

  it 'carries the flag through the tool result of an input failure and keeps it recognised as a failure' do
    error = Scheduling::Error.new(code: 'INVALID_DATE', message: 'x', status: :unprocessable_content, details: { mutation_executed: false })
    result = Captain::ToolResult.normalize(described_class.failure_output(error))

    expect(result).to include(success: false, audit: include(error_class: 'business'), data: include(error_class: 'business'))
  end

  it 'reports a provider failure of an appointment as technical whatever its stored status says' do
    appointment = create(:scheduling_appointment)

    result = described_class.provider_failure(appointment, action: 'update_appointment')

    expect(result).to include(success: false, reason: 'staff_will_help', provider_confirmed: false, error_class: 'technical',
                              provider_confirmation_operation: 'move_reception')
    expect(Captain::ToolResult.normalize(result.to_json)).to include(success: false)
  end

  %w[INVALID_DATE INVALID_DATE_RANGE INVALID_SERVICE_ID UNKNOWN_SERVICE PROVIDER_UNAVAILABLE INTERNAL_FAILURE].each do |code|
    it "keeps #{code} and safe repair guidance without exposing exception details" do
      error = Scheduling::Error.new(code: code, message: 'PRIVATE patient body and credentials', status: :unprocessable_content,
                                    details: { secret: 'PRIVATE', patient_id: 42 })
      payload = described_class.failure(error)

      expect(payload).to include(success: false, code: code, reason: code.downcase, correction: be_present)
      expect(payload.to_json).not_to include('PRIVATE', 'credentials', 'patient_id')
      expect(Captain::ToolResult.normalize(payload.to_json)).to include(success: false, retryable: false)
    end
  end

  it 'distinguishes provider unavailability from an internal availability failure' do
    %w[provider_unavailable internal_failure].each do |cause|
      error = Scheduling::Error.new(code: 'MEDELEMENT_AVAILABILITY_UNVERIFIED', message: 'Do not expose provider body',
                                    status: :service_unavailable, details: { provider_reason: cause })
      expect(described_class.failure(error)).to include(reason: cause, code: cause.upcase)
    end
  end

  describe 'a required appointment field the booking lacks' do
    let(:account) { create(:account) }
    let(:error) do
      Crm::Error.new(code: 'VALIDATION_ERROR', message: 'custom_attributes.insurance_number is required', status: :unprocessable_content,
                     details: { 'custom_attributes.insurance_number' => ['is required'] })
    end

    before do
      create(:crm_field_definition, account: account, entity_kind: 'appointment', key: 'insurance_number', label: 'Номер полиса',
                                    required: true)
    end

    it 'is a business failure that names the field by its label, with nothing written and no id' do
      payload = described_class.failure(error, account: account)

      expect(payload).to include(success: false, reason: 'validation_error', code: 'CUSTOM_FIELD_REQUIRED', error_class: 'business',
                                 audit: { mutation_executed: false, failure_stage: 'tool_arguments' })
      expect(payload[:correction]).to include('"Номер полиса"', 'Ask the patient', 'list_appointment_custom_fields')
      expect(payload[:correction]).not_to match(/insurance_number|\d/)
    end

    it 'falls back to the key when the field is unknown or inactive, and without an account' do
      expect(described_class.failure(error)[:correction]).to include('"insurance_number"')
      account.crm_field_definitions.update_all(active: false) # rubocop:disable Rails/SkipsModelValidations
      expect(described_class.failure(error, account: account)[:correction]).to include('"insurance_number"')
    end

    it 'reaches the agent as a failure it can correct in the same run' do
      result = Captain::ToolResult.normalize(described_class.failure_output(error, account: account))

      expect(result).to include(success: false, retryable: false, error: include('Номер полиса'),
                                audit: include(error_class: 'business', failure_stage: 'tool_arguments', mutation_executed: false),
                                data: include(code: 'CUSTOM_FIELD_REQUIRED', error_class: 'business'))
    end

    it 'keeps the plain validation failure for any other field error' do
      other = Crm::Error.new(code: 'VALIDATION_ERROR', message: 'custom_attributes.insurance_number is not a known active field',
                             status: :unprocessable_content)

      expect(described_class.failure(other, account: account)).to eq(success: false, reason: 'validation_error', error_class: 'business')
    end
  end

  describe 'an answer that nothing was changed or created' do
    let(:account) { create(:account) }
    let(:resource) { create(:scheduling_resource, account: account, name: 'Therapist Abdrakhmanova', timezone: 'Asia/Almaty') }
    let(:appointment) { create(:scheduling_appointment, account: account, resource: resource, starts_at: Time.zone.parse('2026-10-15 11:00 +0500')) }

    it 'names the statuses the monitoring flag reads' do
      expect(Captain::ToolResult::NO_CHANGE_STATUSES).to contain_exactly(described_class::STATUS_UNCHANGED, described_class::STATUS_ALREADY_BOOKED)
    end

    it 'tells an update that asked for what the appointment has where it is and with whom, in the clinic time of the specialist' do
      result = described_class.unchanged(appointment, action: 'update_appointment')

      expect(result).to include(
        success: true, appointment_id: appointment.id, local_date: '15.10.2026', local_time: '11:00', status: 'unchanged',
        note: 'The appointment is already at 15.10.2026 11:00 with Therapist Abdrakhmanova; nothing was changed.'
      )
      expect(Captain::ToolResult.no_change?(result.to_json)).to be(true)
    end

    it 'tells a booking that exists already the same way, and that nothing was created' do
      result = described_class.already_booked(appointment, action: 'create_appointment')

      expect(result).to include(
        success: true, appointment_id: appointment.id, status: 'already_booked',
        note: 'The appointment is already booked at 15.10.2026 11:00 with Therapist Abdrakhmanova; nothing was created.'
      )
      expect(Captain::ToolResult.no_change?(result.to_json)).to be(true)
    end

    it 'gives staff the same line for an update that changed nothing' do
      expect(described_class.unchanged_note(appointment)).to eq(
        'The appointment is already at 15.10.2026 11:00 with Therapist Abdrakhmanova; nothing was changed.'
      )
    end

    it 'reports the provider state instead when the existing appointment is not confirmed: no success the agent could repeat' do
      appointment.update!(custom_attributes: { 'medelement_provider_sync_status' => 'pending' })

      result = described_class.already_booked(appointment, action: 'create_appointment')

      expect(result).to include(success: false, provider_confirmed: false)
      expect(result[:status]).not_to eq('already_booked')
      expect(Captain::ToolResult.no_change?(result.to_json)).to be(false)
    end
  end

  describe 'a booking without a service for a specialist who offers several' do
    let(:services) { [{ id: 12, name: 'Control visit' }, { id: 15, name: 'First visit' }] }
    let(:error) do
      Scheduling::Error.new(code: 'SERVICE_REQUIRED', message: 'The specialist offers several services', status: :unprocessable_content,
                            details: { mutation_executed: false, services: services })
    end

    it 'is a business answer that lists the services by ID and name, with nothing written' do
      payload = described_class.failure(error)

      expect(payload).to include(success: false, reason: 'validation_error', code: 'SERVICE_REQUIRED', error_class: 'business',
                                 services: services, audit: { mutation_executed: false, failure_stage: 'tool_arguments' })
      expect(payload[:correction]).to include('service_id', 'ask the patient')
    end

    it 'says when the list is partial and where to find the other services' do
      partial = Scheduling::Error.new(code: 'SERVICE_REQUIRED', message: 'x', status: :unprocessable_content,
                                      details: { mutation_executed: false, services: services, more: 7 })

      payload = described_class.failure(partial)

      expect(payload).to include(more_services: 7, services: services)
      expect(payload[:correction]).to end_with('The list is partial: search_scheduling_services finds the others.')
      expect(described_class.failure(error)).not_to include(:more_services)
    end

    it 'reaches the agent as a failure it can correct in the same run, and the runtime reads it as a business answer' do
      output = described_class.failure_output(error)
      result = Captain::ToolResult.normalize(output)

      expect(result).to include(success: false, retryable: false, error: include('service_id'),
                                audit: include(error_class: 'business', failure_stage: 'tool_arguments', mutation_executed: false),
                                data: include(code: 'SERVICE_REQUIRED', services: services))
      expect(result[:data]).not_to include(:correction)
      expect(Captain::Runtime::ToolFailure.classify(output)).to eq('business')
      expect(Captain::Runtime::ToolFailure.business_answer?(output)).to be(true)
    end
  end
end