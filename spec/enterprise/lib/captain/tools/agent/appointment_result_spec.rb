require 'rails_helper'

RSpec.describe Captain::Tools::Agent::AppointmentResult do
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

  it 'maps only verified slot conflicts to time_taken' do
    conflict = Scheduling::Error.new(code: 'APPOINTMENT_SLOT_UNAVAILABLE', message: 'Unavailable', status: :conflict)
    unknown = Scheduling::Error.new(code: 'MEDELEMENT_AVAILABILITY_UNVERIFIED', message: 'Unknown', status: :service_unavailable)

    expect(described_class.failure(conflict)).to eq(success: false, reason: 'time_taken')
    expect(described_class.failure(unknown)).to eq(success: false, reason: 'staff_will_help')
  end

  it 'maps the provider horizon and includes only the last bookable date' do
    error = Scheduling::Error.new(
      code: 'MEDELEMENT_HORIZON_EXCEEDED', message: 'Do not expose this text', status: :unprocessable_content,
      details: { last_available_date: '2026-10-15', provider_code: 'internal' }
    )

    expect(described_class.failure(error)).to eq(success: false, reason: 'schedule_not_open', last_available_date: '2026-10-15')
  end

  it 'maps the 45-second unknown and failed outcomes to staff_will_help' do
    %w[MEDELEMENT_BOOKING_UNKNOWN MEDELEMENT_BOOKING_FAILED].each do |code|
      error = Scheduling::Error.new(code: code, message: 'Provider details', status: :unprocessable_content)
      expect(described_class.failure(error)).to eq(success: false, reason: 'staff_will_help')
    end
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
end
