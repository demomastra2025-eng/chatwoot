require 'rails_helper'

RSpec.describe 'Public appointment input error contracts' do
  let(:account) { create(:account).tap { |record| record.enable_features!('scheduling') } }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:contact) { create(:contact, account: account) }
  let(:conversation) { create(:conversation, account: account, contact: contact) }
  let(:resource) { create(:scheduling_resource, account: account, custom_attributes: { 'medelement_specialist_code' => 'doctor-1' }) }
  let(:appointment) { create(:scheduling_appointment, account: account, resource: resource, contact: contact, conversation: conversation) }
  let(:context) { Struct.new(:state).new({ conversation: { id: conversation.id } }) }
  let(:starts_at) { '2026-10-12T09:00:00+05:00' }

  def failure_payload(result)
    payload = JSON.parse(result)
    expect(Captain::ToolResult.normalize(result)).to include(success: false, retryable: false)
    payload
  end

  [Captain::Tools::CreateAppointmentTool, Captain::Tools::UpdateAppointmentTool].each do |tool_class|
    context tool_class.name do
      let(:tool) { tool_class.new(assistant) }
      let(:args) do
        tool_class == Captain::Tools::CreateAppointmentTool ? { resource_id: resource.id, starts_at: starts_at } :
          { appointment_id: appointment.id }
      end

      it 'rejects invalid dates and reversed intervals before any appointment/provider mutation' do
        args
        expect(Integrations::Medelement::Client).not_to receive(:new)
        count = Scheduling::Appointment.count
        original = appointment.attributes if tool_class == Captain::Tools::UpdateAppointmentTool

        payload = failure_payload(tool.perform(context, **args.merge(starts_at: '2026-02-30T09:00:00+05:00')))
        expect(payload).to include('code' => 'INVALID_DATE', 'reason' => 'invalid_date')
        payload = failure_payload(tool.perform(context, **args.merge(starts_at: starts_at, ends_at: starts_at)))
        expect(payload).to include('code' => 'INVALID_DATE_RANGE', 'reason' => 'invalid_date_range')

        expect(Scheduling::Appointment.count).to eq(count)
        expect(appointment.reload.attributes).to eq(original) if original
      end

      it 'rejects a service belonging to another account without returning its contents' do
        other_service = create(:scheduling_service, name: 'PRIVATE service')
        args
        expect(Integrations::Medelement::Client).not_to receive(:new)
        payload = failure_payload(tool.perform(context, **args.merge(service_id: other_service.id)))

        expect(payload).to include('code' => 'UNKNOWN_SERVICE', 'reason' => 'unknown_service')
        expect(payload.to_json).not_to include('PRIVATE')
      end

      it 'rejects a nonpositive calculated interval before any provider call or write' do
        args
        count = Scheduling::Appointment.count
        original = appointment.attributes if tool_class == Captain::Tools::UpdateAppointmentTool
        expect(Integrations::Medelement::Client).not_to receive(:new)

        [0, -15].each do |duration|
          payload = failure_payload(tool.perform(context, **args.merge(duration_min: duration)))
          expect(payload).to include('code' => 'INVALID_DATE_RANGE', 'reason' => 'invalid_date_range')
        end
        expect(Scheduling::Appointment.count).to eq(count)
        expect(appointment.reload.attributes).to eq(original) if original
      end
    end
  end

  it 'moves the complete native interval when only a later start is supplied' do
    resource.update!(custom_attributes: {})
    old_start = Time.zone.parse(starts_at)
    appointment.update!(starts_at: old_start, ends_at: old_start + 30.minutes, duration_min: 30)
    new_start = old_start + 2.hours
    create(:scheduling_work_rule, resource: resource, weekday: new_start.in_time_zone(resource.timezone).wday)
    expect(Integrations::Medelement::Client).not_to receive(:new)

    result = Captain::Tools::UpdateAppointmentTool.new(assistant).perform(context, appointment_id: appointment.id, starts_at: new_start.iso8601)

    expect(JSON.parse(result)).to include('success' => true, 'status' => 'updated')
    expect(appointment.reload).to have_attributes(starts_at: new_start, ends_at: new_start + 30.minutes, duration_min: 30)
  end
end
