require 'rails_helper'

RSpec.describe Captain::Tools::Operations::AppointmentOperations do
  let(:account) { create(:account) }
  let(:actor) { create(:user, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:conversation) { create(:conversation, account: account) }
  let(:operation) { described_class.new(assistant: assistant, conversation: conversation, actor: actor) }

  before do
    account.enable_features!('scheduling')
  end

  it 'allows a resource-only update through assign without requiring update_fields' do
    appointment = create(:scheduling_appointment, account: account, contact: conversation.contact)
    replacement_resource = create(:scheduling_resource, account: account)
    AccessControl::SystemRoleBootstrapper.call(account: account)
    AccessControl::LegacyRoleAssigner.call(account: account, apply: true)
    AccessControl::ModeTransition.call(account: account, to: :shadow)
    AccessControl::ModeTransition.call(account: account, to: :enforced)
    grants = account.account_users.find_by!(user: actor).access_role.grants.where(resource: 'appointments')
    grants.find_by!(capability: 'assign').update!(access_scope: 'all')
    grants.find_by!(capability: 'update_fields').update!(access_scope: 'none')
    allow(Captain::ContextFields).to receive(:appointment_for).and_return(appointment)
    upsert = instance_double(Scheduling::Appointments::UpsertService, perform: appointment)

    expect(Scheduling::Appointments::UpsertService).to receive(:new).with(
      account: account,
      params: { resource_id: replacement_resource.id },
      appointment: appointment,
      actor: actor,
      required_capabilities: []
    ).and_return(upsert)

    expect(operation.update_current_appointment(resource_id: replacement_resource.id)).to eq(appointment)
  end

  it 'enforces the final create scope independently from assign scope' do
    outsider = create(:user, account: account)
    conversation.contact.update!(owner: outsider)
    resource = create(:scheduling_resource, account: account, user: outsider, timezone: 'Asia/Almaty')
    create(:scheduling_work_rule, resource: resource, weekday: 1, start_minute: 9 * 60, end_minute: 18 * 60)
    AccessControl::SystemRoleBootstrapper.call(account: account)
    AccessControl::LegacyRoleAssigner.call(account: account, apply: true)
    AccessControl::ModeTransition.call(account: account, to: :shadow)
    AccessControl::ModeTransition.call(account: account, to: :enforced)
    grants = account.account_users.find_by!(user: actor).access_role.grants.where(resource: 'appointments')
    grants.find_by!(capability: 'create').update!(access_scope: 'own')
    grants.find_by!(capability: 'assign').update!(access_scope: 'all')
    arguments = {
      resource_id: resource.id,
      starts_at: Time.zone.parse('2026-04-20 09:00:00 +0500').iso8601,
      duration_min: 30
    }

    expect { operation.create_appointment(**arguments) }.to raise_error(Pundit::NotAuthorizedError)

    conversation.contact.update!(owner: actor)

    expect(operation.create_appointment(**arguments)).to have_attributes(
      contact_id: conversation.contact_id,
      resource_id: resource.id
    )
  end

  it 'rejects customer-agent create without a dashboard actor, even with a claimed agent scope' do
    resource = create(:scheduling_resource, account: account, timezone: 'Asia/Almaty')
    create(:scheduling_work_rule, resource: resource, weekday: 1, start_minute: 9 * 60, end_minute: 18 * 60)
    args = { resource_id: resource.id, starts_at: Time.zone.parse('2026-04-20 09:00:00 +0500').iso8601, duration_min: 30 }

    [nil, assistant].each do |untrusted_actor|
      customer_operation = described_class.new(assistant: assistant, conversation: conversation, actor: untrusted_actor,
                                               execution_scope: Captain::ToolAccess::SCOPE_AGENT)
      expect { customer_operation.create_appointment(**args) }.to raise_error(Pundit::NotAuthorizedError)
    end
    expect(account.scheduling_appointments.count).to eq(0)
  end

  it 'does not let a dashboard user bypass their appointment role with a claimed agent scope' do
    outsider = create(:user)
    customer_operation = described_class.new(assistant: assistant, conversation: conversation, actor: outsider,
                                             execution_scope: Captain::ToolAccess::SCOPE_AGENT)
    expect do
      customer_operation.create_appointment(resource_id: create(:scheduling_resource, account: account).id,
                                            starts_at: 1.day.from_now.iso8601, duration_min: 30)
    end.to raise_error(Pundit::NotAuthorizedError)
    expect(account.scheduling_appointments.count).to eq(0)
  end

  it 'does not invoke the upsert for an empty update with no actor or with an employee' do
    appointment = create(:scheduling_appointment, account: account, conversation: conversation, contact: conversation.contact)
    expect(Scheduling::Appointments::UpsertService).not_to receive(:new)

    [nil, assistant].each do |untrusted_actor|
      untrusted_operation = described_class.new(assistant: assistant, conversation: conversation, actor: untrusted_actor)
      expect { untrusted_operation.update_current_appointment(appointment_id: appointment.id) }.to raise_error(Pundit::NotAuthorizedError)
    end

    expect { operation.update_current_appointment(appointment_id: appointment.id) }.to raise_error(ArgumentError, /No appointment fields/)
  end

  it 'does not grant a legacy assistant actor local appointment creation' do
    resource = create(:scheduling_resource, account: account, timezone: 'Asia/Almaty')
    create(:scheduling_work_rule, resource: resource, weekday: 1, start_minute: 9 * 60, end_minute: 18 * 60)
    customer_operation = described_class.new(assistant: assistant, conversation: conversation, actor: assistant)

    expect do
      customer_operation.create_appointment(
        resource_id: resource.id,
        starts_at: Time.zone.parse('2026-04-20 09:00:00 +0500').iso8601,
        duration_min: 30
      )
    end.to raise_error(Pundit::NotAuthorizedError)
    expect(account.scheduling_appointments.count).to eq(0)
  end

  it 'refuses provider-backed AI appointments before invoking the upsert or provider I/O' do
    resource = create(
      :scheduling_resource,
      account: account,
      custom_attributes: { 'medelement_specialist_code' => 'specialist-1' }
    )
    customer_operation = described_class.new(assistant: assistant, conversation: conversation, actor: assistant)
    allow(Scheduling::Appointments::UpsertService).to receive(:new)

    expect do
      customer_operation.create_appointment(resource_id: resource.id, starts_at: Time.current.iso8601, duration_min: 30)
    end.to raise_error(Pundit::NotAuthorizedError)
    expect(Scheduling::Appointments::UpsertService).not_to have_received(:new)
    expect(account.scheduling_appointments.count).to eq(0)
  end
end
