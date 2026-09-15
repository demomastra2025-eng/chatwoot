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

  it 'preserves customer-agent create semantics without a dashboard actor' do
    resource = create(:scheduling_resource, account: account, timezone: 'Asia/Almaty')
    create(:scheduling_work_rule, resource: resource, weekday: 1, start_minute: 9 * 60, end_minute: 18 * 60)
    customer_operation = described_class.new(assistant: assistant, conversation: conversation)

    expect(
      customer_operation.create_appointment(
        resource_id: resource.id,
        starts_at: Time.zone.parse('2026-04-20 09:00:00 +0500').iso8601,
        duration_min: 30
      )
    ).to be_persisted
  end
end
