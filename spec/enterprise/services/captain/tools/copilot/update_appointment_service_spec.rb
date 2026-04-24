require 'rails_helper'

RSpec.describe Captain::Tools::Copilot::UpdateAppointmentService do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:contact) { create(:contact, account: account, name: 'Aruzhan', phone_number: '+77000000000') }
  let(:conversation) { create(:conversation, account: account, contact: contact) }
  let(:service) { described_class.new(assistant, user: user, conversation: conversation) }
  let(:resource) { create(:scheduling_resource, account: account, timezone: 'Asia/Almaty', slot_duration_min: 30) }
  let(:new_resource) { create(:scheduling_resource, account: account, timezone: 'Asia/Almaty', slot_duration_min: 20) }
  let(:consultation) { create(:scheduling_service, account: account, name: 'Consultation', duration_min: 45, base_price: 20_000) }
  let(:follow_up) { create(:scheduling_service, account: account, name: 'Follow-up', duration_min: 20, base_price: 10_000) }
  let!(:appointment) do
    create(
      :scheduling_appointment,
      account: account,
      conversation: conversation,
      contact: contact,
      resource: resource,
      service: consultation,
      starts_at: Time.zone.parse('2026-04-20 09:00:00 +0500'),
      ends_at: Time.zone.parse('2026-04-20 09:45:00 +0500'),
      duration_min: 45,
      custom_attributes: { 'source' => 'captain' }
    )
  end
  let(:updated_start) { Time.zone.parse('2026-04-20 11:00:00 +0500') }

  before do
    account.enable_features!('scheduling')
    create(:scheduling_work_rule, resource: resource, weekday: 1, start_minute: 9 * 60, end_minute: 18 * 60)
    create(:scheduling_work_rule, resource: new_resource, weekday: 1, start_minute: 9 * 60, end_minute: 18 * 60)
    create(:scheduling_service_price, account: account, service: consultation, resource: resource, active: true, price: 20_000)
    create(:scheduling_service_price, account: account, service: follow_up, resource: new_resource, active: true, price: 10_000)
  end

  describe '#execute' do
    it 'recomputes ends_at from duration and accepts object custom_attributes' do
      service.execute(
        resource_id: new_resource.id,
        service_id: follow_up.id,
        starts_at: updated_start.iso8601,
        custom_attributes: { 'source' => 'captain', 'rescheduled_by' => 'agent' }
      )

      appointment.reload

      expect(appointment).to have_attributes(
        resource_id: new_resource.id,
        service_id: follow_up.id,
        duration_min: 20,
        starts_at: updated_start,
        ends_at: updated_start + 20.minutes
      )
      expect(appointment.custom_attributes).to include(
        'source' => 'captain',
        'rescheduled_by' => 'agent',
        'service_ids' => [follow_up.id]
      )
    end

    it 'returns an error when explicit ends_at conflicts with duration_min' do
      result = service.execute(
        starts_at: updated_start.iso8601,
        ends_at: (updated_start + 45.minutes).iso8601,
        duration_min: 20
      )

      expect(result).to start_with('ERROR:')
      expect(result).to include('duration_min does not match ends_at')
    end
  end
end
