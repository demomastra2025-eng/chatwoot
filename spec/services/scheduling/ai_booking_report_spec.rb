require 'rails_helper'

RSpec.describe Scheduling::AiBookingReport do
  let(:account) { create(:account).tap { |record| record.enable_features!('scheduling') } }
  let(:resource) { create(:scheduling_resource, account: account) }
  let(:contact) { create(:contact, account: account, phone_number: '+77010000001') }
  let(:hook) { create(:integrations_hook, :medelement, account: account) }

  before do
    allow(Integrations::Medelement::CronScheduleService).to receive(:new).and_return(
      instance_double(Integrations::Medelement::CronScheduleService, sync!: true, destroy!: true)
    )
  end

  def appointment(source: 'captain', **attributes)
    create(:scheduling_appointment, account: account, resource: resource, contact: contact,
                                    source: source, starts_at: 1.day.from_now.change(hour: 10),
                                    ends_at: 1.day.from_now.change(hour: 10) + 30.minutes, **attributes)
  end

  def command_for(record, status: 'queued', actor: 'Captain::Assistant', created_at: 6.minutes.ago)
    Integrations::Medelement::ProviderCommand.create!(
      account: account, hook: hook, appointment: record, contact: record.contact,
      operation: 'create_reception', status: status, company_cabinet_code: 'cab-1',
      idempotency_key: "report-command-#{SecureRandom.hex(6)}", created_at: created_at,
      execution_state: { 'request_snapshot' => { 'actor' => { 'type' => actor } } }
    )
  end

  def findings
    described_class.new(account_id: account.id).call.select { |row| row['record_type'] == 'anomaly' }
  end

  it 'finds captain source and legacy snapshot actor, but excludes staff appointments' do
    appointment
    legacy = appointment(source: 'manual', starts_at: 1.day.from_now.change(hour: 11),
                         ends_at: 1.day.from_now.change(hour: 11) + 30.minutes)
    staff = appointment(source: 'manual', starts_at: 1.day.from_now.change(hour: 12),
                        ends_at: 1.day.from_now.change(hour: 12) + 30.minutes)
    command_for(legacy)
    command_for(staff, actor: 'User')

    total = described_class.new(account_id: account.id).call.find { |row| row['record_type'] == 'total' }
    expect(total['ai_appointments']).to eq(2)
    expect(findings.map { |row| row['appointment_id'] }).not_to include(staff.id)
    expect(findings.map { |row| row['appointment_id'] }).to include(legacy.id)
  end

  it 'uses the 5 and 15 minute command thresholds and the 2 minute unbound threshold' do
    warning = appointment
    critical = appointment(starts_at: 1.day.from_now.change(hour: 11), ends_at: 1.day.from_now.change(hour: 11) + 30.minutes)
    fresh = appointment(starts_at: 1.day.from_now.change(hour: 12), ends_at: 1.day.from_now.change(hour: 12) + 30.minutes)
    unbound = appointment(starts_at: 1.day.from_now.change(hour: 13), ends_at: 1.day.from_now.change(hour: 13) + 30.minutes,
                          custom_attributes: { 'medelement_provider_sync_status' => 'pending' })
    fresh_unbound = appointment(starts_at: 1.day.from_now.change(hour: 14), ends_at: 1.day.from_now.change(hour: 14) + 30.minutes,
                                custom_attributes: { 'medelement_provider_sync_status' => 'pending' })
    command_for(warning, created_at: 5.minutes.ago - 2.seconds)
    command_for(critical, created_at: 15.minutes.ago - 2.seconds)
    command_for(fresh, created_at: 5.minutes.ago + 2.seconds)
    unbound.update!(created_at: 2.minutes.ago - 2.seconds)
    fresh_unbound.update!(created_at: 2.minutes.ago + 2.seconds)

    pairs = findings.map { |row| [row['appointment_id'], row['rule']] }
    expect(pairs).to include([warning.id, 'A1_CREATE_PENDING'], [critical.id, 'A1_CREATE_CRITICAL'],
                             [unbound.id, 'A1_UNBOUND_PENDING'])
    expect(pairs).not_to include([fresh.id, 'A1_CREATE_PENDING'], [critical.id, 'A1_CREATE_PENDING'],
                                 [fresh_unbound.id, 'A1_UNBOUND_PENDING'])
  end

  it 'waits five minutes before reporting reconciliation required' do
    record = appointment
    command = command_for(record, status: 'v2_reconciliation_required')
    command.update!(updated_at: 5.minutes.ago + 2.seconds)
    expect(findings.map { |row| row['rule'] }).not_to include('A2_RECONCILIATION')

    command.update!(updated_at: 5.minutes.ago - 2.seconds)
    expect(findings.map { |row| row['rule'] }).to include('A2_RECONCILIATION')
  end

  it 'keeps patient action separate from failed and unknown commands' do
    failed = appointment
    unknown = appointment(starts_at: 1.day.from_now.change(hour: 11), ends_at: 1.day.from_now.change(hour: 11) + 30.minutes)
    waiting = appointment(starts_at: 1.day.from_now.change(hour: 12), ends_at: 1.day.from_now.change(hour: 12) + 30.minutes)
    command_for(failed, status: 'failed')
    command_for(unknown, status: 'provider_status_unknown')
    command_for(waiting, status: 'awaiting_patient_selection')

    expect(findings.map { |row| [row['appointment_id'], row['rule'], row['severity']] }).to include(
      [failed.id, 'A2_COMMAND_FAILED', 'warning'],
      [unknown.id, 'A2_PROVIDER_UNKNOWN', 'critical'],
      [waiting.id, 'A2_AWAITING_PATIENT', 'needs_human']
    )
  end

  it 'does not treat family members with a shared phone as duplicate patients' do
    first = appointment(client_phone: '+77010000001')
    other_contact = create(:contact, account: account)
    second = appointment(contact: other_contact, client_phone: '+77010000001')

    expect(findings.select { |row| row['rule'] == 'A4_DUPLICATE' }).to be_empty
    expect(findings.map { |row| row['appointment_id'] }).to include(first.id, second.id)
  end

  it 'detects an active duplicate, doctor overlap and cabinet overlap' do
    first = appointment(custom_attributes: { 'medelement_cabinet_code' => 'cab-1' })
    duplicate = appointment(custom_attributes: { 'medelement_cabinet_code' => 'cab-1' })
    other_contact = create(:contact, account: account)
    overlap = appointment(contact: other_contact, starts_at: first.starts_at + 15.minutes,
                          ends_at: first.ends_at + 15.minutes)
    other_resource = create(:scheduling_resource, account: account)
    cabinet = appointment(resource: other_resource, contact: other_contact,
                          custom_attributes: { 'medelement_cabinet_code' => 'cab-1' })

    pairs = findings.map { |row| [row['appointment_id'], row['rule']] }
    expect(pairs).to include([first.id, 'A4_DUPLICATE'], [duplicate.id, 'A4_DUPLICATE'],
                             [overlap.id, 'A4_DOCTOR_OVERLAP'], [cabinet.id, 'A4_CABINET_OVERLAP'])
  end

  it 'does not flag completed or adjacent appointments as active overlaps' do
    first = appointment
    appointment(starts_at: first.ends_at, ends_at: first.ends_at + 30.minutes)
    appointment(status: 'completed')

    expect(findings.map { |row| row['rule'] }).not_to include('A4_DUPLICATE', 'A4_DOCTOR_OVERLAP')
  end

  it 'reports a missing held notification after success and clears it when a reminder exists' do
    record = appointment(custom_attributes: { 'appointment_created_notification_hold' => { 'rule_ids' => [1] } })
    command = command_for(record, status: 'succeeded', created_at: 11.minutes.ago)
    command.update!(executed_at: 10.minutes.ago + 2.seconds)
    expect(findings.map { |row| row['rule'] }).not_to include('A6_NOTIFICATION_MISSING')

    command.update!(executed_at: 10.minutes.ago - 2.seconds)
    expect(findings.map { |row| row['rule'] }).to include('A6_NOTIFICATION_MISSING')

    create(:reminder, account: account, remindable: record, created_at: 10.minutes.ago)
    expect(findings.map { |row| row['rule'] }).not_to include('A6_NOTIFICATION_MISSING')
  end

  it 'requires an LLM tool failure within five minutes of a public claim' do
    assistant = create(:captain_assistant, account: account)
    inbox = create(:inbox, account: account)
    conversation = create(:conversation, account: account, inbox: inbox, contact: contact)
    message = create(:message, account: account, inbox: inbox, conversation: conversation,
                               sender: assistant, message_type: :outgoing, content: 'Вы записаны на приём')
    LlmEvent.create!(account: account, conversation: conversation, event_name: 'llm.tool.complete',
                     tool_name: 'create_appointment', payload: { 'result_success' => false },
                     created_at: message.created_at - 5.minutes - 2.seconds)
    expect(findings.map { |row| row['rule'] }).not_to include('A5_CLAIM_WITHOUT_SUCCESS')

    LlmEvent.create!(account: account, conversation: conversation, event_name: 'llm.tool.complete',
                     tool_name: 'create_appointment', payload: { 'result_success' => false },
                     created_at: message.created_at - 5.minutes + 2.seconds)
    expect(findings.map { |row| row['rule'] }).to include('A5_CLAIM_WITHOUT_SUCCESS')
  end

  it 'reports a false booking claim from a failed tool trace without emitting message text' do
    appointment
    assistant = create(:captain_assistant, account: account)
    inbox = create(:inbox, account: account)
    conversation = create(:conversation, account: account, inbox: inbox, contact: contact)
    create(:message, account: account, inbox: inbox, conversation: conversation, sender: assistant,
                     message_type: :outgoing, content: 'Вы записаны на приём',
                     additional_attributes: { 'captain_trace' => { 'tool_steps' => [
                       { 'tool_name' => 'create_appointment', 'event' => 'failed' }
                     ] } })

    result = described_class.new(account_id: account.id).call
    expect(result.map { |row| row['rule'] }).to include('A5_CLAIM_WITHOUT_SUCCESS')
    expect(result.to_json).not_to include('Вы записаны', contact.name, contact.phone_number)
    expect(result.find { |row| row['rule'] == 'A5_CLAIM_WITHOUT_SUCCESS' }['appointment_id']).to be_nil
  end

  it 'does not classify a successful tool trace as a false claim' do
    assistant = create(:captain_assistant, account: account)
    inbox = create(:inbox, account: account)
    conversation = create(:conversation, account: account, inbox: inbox, contact: contact)
    create(:message, account: account, inbox: inbox, conversation: conversation, sender: assistant,
                     message_type: :outgoing, content: 'Вы записаны на приём',
                     additional_attributes: { 'captain_trace' => { 'tool_steps' => [
                       { 'tool_name' => 'create_appointment', 'event' => 'finish' }
                     ] } })

    expect(findings.map { |row| row['rule'] }).not_to include('A5_CLAIM_WITHOUT_SUCCESS')
  end

  it 'detects creation after start and a determinable outside-work-window start' do
    start = 1.day.ago.in_time_zone(resource.timezone).change(hour: 2, min: 0, sec: 0)
    record = appointment(starts_at: start, ends_at: start + 30.minutes)
    local_day = (record.starts_at.in_time_zone(resource.timezone)).wday
    create(:scheduling_work_rule, account: account, resource: resource,
                                  weekday: local_day, start_minute: 9 * 60, end_minute: 18 * 60)

    expect(findings.map { |row| row['rule'] }).to include('A8_CREATED_AFTER_START')
    expect(findings.map { |row| row['rule'] }).to include('A8_OUTSIDE_WORK_WINDOW')
  end

  it 'marks a whole-hour time-zone shift as a symptom for review' do
    start = 1.day.from_now.in_time_zone(resource.timezone).change(hour: 4, min: 0, sec: 0)
    create(:scheduling_work_rule, account: account, resource: resource,
                                  weekday: start.in_time_zone(resource.timezone).wday,
                                  start_minute: 9 * 60, end_minute: 18 * 60)
    appointment(starts_at: start, ends_at: start + 30.minutes)

    expect(findings.map { |row| row['rule'] }).to include('A8_TIMEZONE_SUSPECT')
  end
end
