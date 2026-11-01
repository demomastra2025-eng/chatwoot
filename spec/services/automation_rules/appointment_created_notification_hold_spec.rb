require 'rails_helper'

RSpec.describe AutomationRules::AppointmentCreatedNotificationHold do
  include ActiveJob::TestHelper
  include ActiveSupport::Testing::TimeHelpers

  around { |example| travel_to(Time.zone.parse('2026-10-20 08:00')) { example.run } }

  let(:account) { create(:account) }
  let(:resource) do
    create(:scheduling_resource, account: account, custom_attributes: { 'medelement_specialist_code' => 'specialist-1' })
  end
  let(:contact) do
    create(:contact, account: account, name: 'Айжан', last_name: 'Касымова', phone_number: '+77000000001')
  end
  let(:service) do
    create(:scheduling_service, account: account, custom_attributes: { 'medelement_nomenclature_code' => 'service-1' })
  end
  let(:actor) { create(:user, account: account) }
  let(:conversation) { create(:conversation, account: account, contact: contact) }
  let!(:appointment) do
    create(:scheduling_appointment, account: account, resource: resource, service: service, contact: contact, conversation: conversation,
                                    custom_attributes: { Integrations::Medelement::AppointmentProviderStatus::ATTRIBUTE_KEY => 'pending' })
  end
  let(:rule) do
    create(
      :automation_rule, account: account, event_name: 'appointment_created',
                        conditions: [{ attribute_key: 'status', filter_operator: 'equal_to', values: ['scheduled'], query_operator: nil }],
                        actions: [
                          { action_name: 'change_appointment_status', action_params: ['confirmed'] },
                          { action_name: 'create_touch', action_params: { body: 'Подтверждение записи', delay_minutes: 10 } },
                          { action_name: 'send_webhook_event', action_params: ['https://example.com/hooks/appointments'] }
                        ]
    )
  end

  before do
    account.enable_features!('scheduling')
    rule
    settings = attributes_for(:integrations_hook, :medelement)[:settings].merge('write_enabled' => true)
    create(:integrations_hook, :medelement, account: account, settings: settings)
    clear_enqueued_jobs
  end

  def command_for_appointment
    command = Integrations::Medelement::ProviderCommand.create!(
      account: account, appointment: appointment, contact: contact, operation: 'create_reception', status: 'queued',
      idempotency_key: SecureRandom.uuid, company_cabinet_code: 'cabinet-1',
      desired_starts_at: appointment.starts_at, desired_ends_at: appointment.ends_at
    )
    status = Integrations::Medelement::AppointmentProviderStatus
    appointment.update_columns(custom_attributes: appointment.custom_attributes.merge(status::COMMAND_ID_KEY => command.id)) # rubocop:disable Rails/SkipsModelValidations
    command
  end

  it 'holds only notifications until the exact create succeeds, then releases them once' do
    event = Events::Base.new('appointment_created', Time.zone.now, appointment: appointment, performed_by: actor)
    SchedulingAutomationRuleListener.instance.appointment_created(event)

    expect(appointment.reload.status).to eq('confirmed')
    expect(account.reminders.where(remindable: appointment)).to be_empty
    expect(enqueued_jobs.count { |job| job[:job] == WebhookJob }).to eq(0)

    command = command_for_appointment
    described_class.new(command: command).perform
    expect(account.reminders.where(remindable: appointment)).to be_empty

    command.update!(status: 'succeeded')
    clear_enqueued_jobs
    AutomationRules::ReleaseAppointmentCreatedNotificationsJob.perform_now
    expect(enqueued_jobs.count { |job| job[:job] == AutomationRules::ReleaseAppointmentCreatedNotificationsJob }).to eq(1)
    AutomationRules::ReleaseAppointmentCreatedNotificationsJob.perform_now(command.id)
    2.times { described_class.new(command: command).perform }
    SchedulingAutomationRuleListener.instance.appointment_created(event)

    expect(account.reminders.where(remindable: appointment).count).to eq(1)
    expect(enqueued_jobs.count { |job| job[:job] == WebhookJob }).to eq(1)
  end

  it 'keeps the bound create command while a non-notifying status action runs' do
    command = command_for_appointment
    event = Events::Base.new('appointment_created', Time.zone.now, appointment: appointment, performed_by: actor)

    SchedulingAutomationRuleListener.instance.appointment_created(event)

    expect(appointment.reload.status).to eq('confirmed')
    expect(appointment.custom_attributes[Integrations::Medelement::AppointmentProviderStatus::COMMAND_ID_KEY]).to eq(command.id)
  end

  it 'never releases held notifications for failed or unknown commands' do
    SchedulingAutomationRuleListener.instance.appointment_created(
      Events::Base.new('appointment_created', Time.zone.now, appointment: appointment, performed_by: actor)
    )
    command = command_for_appointment

    %w[failed provider_status_unknown].each do |status|
      command.update!(status: status)
      described_class.new(command: command).perform
    end

    expect(account.reminders.where(remindable: appointment)).to be_empty
    expect(enqueued_jobs.count { |job| job[:job] == WebhookJob }).to eq(0)
  end

  it 'finds a completed notification instead of creating it again during recovery' do
    SchedulingAutomationRuleListener.instance.appointment_created(
      Events::Base.new('appointment_created', Time.zone.now, appointment: appointment, performed_by: actor)
    )
    command = command_for_appointment
    command.update!(status: 'succeeded')
    described_class.new(command: command).perform
    reminder = account.reminders.find_by!(remindable: appointment)
    reminder.update_columns(status: Reminder.statuses.fetch('completed'), completed_at: Time.current) # rubocop:disable Rails/SkipsModelValidations

    state = command.reload.execution_state.except(described_class::DONE_KEY, described_class::COMPLETE_KEY)
    command.update!(execution_state: state)
    described_class.new(command: command).perform

    expect(account.reminders.where(remindable: appointment).count).to eq(1)
  end

  it 'skips holding and releasing notifications when booked with fewer minutes than min_minutes_before_appointment' do
    rule.update!(min_minutes_before_appointment: 60)
    short_appt = create(
      :scheduling_appointment, account: account, resource: resource, service: service, contact: contact, conversation: conversation,
                               starts_at: 45.minutes.from_now, ends_at: 75.minutes.from_now,
                               custom_attributes: { Integrations::Medelement::AppointmentProviderStatus::ATTRIBUTE_KEY => 'pending' }
    )
    clear_enqueued_jobs

    SchedulingAutomationRuleListener.instance.appointment_created(
      Events::Base.new('appointment_created', Time.zone.now, appointment: short_appt, performed_by: actor)
    )

    expect(short_appt.reload.status).to eq('confirmed')
    expect(short_appt.custom_attributes).not_to have_key(described_class::HOLD_KEY)
    expect(account.reminders.where(remindable: short_appt)).to be_empty
    expect(enqueued_jobs.count { |job| job[:job] == WebhookJob }).to eq(0)
  end

  it 'releases held notifications when booked 62 minutes ahead even if command succeeds at 57 minutes remaining' do
    rule.update!(min_minutes_before_appointment: 60)
    ahead_appt = create(
      :scheduling_appointment, account: account, resource: resource, service: service, contact: contact, conversation: conversation,
                               starts_at: 62.minutes.from_now, ends_at: 92.minutes.from_now,
                               custom_attributes: { Integrations::Medelement::AppointmentProviderStatus::ATTRIBUTE_KEY => 'pending' }
    )
    SchedulingAutomationRuleListener.instance.appointment_created(
      Events::Base.new('appointment_created', Time.zone.now, appointment: ahead_appt, performed_by: actor)
    )
    command = Integrations::Medelement::ProviderCommand.create!(
      account: account, appointment: ahead_appt, contact: contact, operation: 'create_reception', status: 'succeeded',
      idempotency_key: SecureRandom.uuid, company_cabinet_code: 'cabinet-1',
      desired_starts_at: ahead_appt.starts_at, desired_ends_at: ahead_appt.ends_at
    )
    status_key = Integrations::Medelement::AppointmentProviderStatus::COMMAND_ID_KEY
    ahead_appt.update_columns(custom_attributes: ahead_appt.reload.custom_attributes.merge(status_key => command.id)) # rubocop:disable Rails/SkipsModelValidations
    clear_enqueued_jobs

    travel 5.minutes
    described_class.new(command: command).perform
    reminder = account.reminders.find_by!(remindable: ahead_appt)
    expect(Reminders::StaleAppointmentNoticePolicy.new(reminder: reminder, now: Time.current).stale_reason).to be_nil
    expect(enqueued_jobs.count { |job| job[:job] == WebhookJob }).to eq(1)
  end
end
