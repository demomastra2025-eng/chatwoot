require 'rails_helper'

RSpec.describe Captain::Tools::Copilot::SearchAvailableSlotsService do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:service) { described_class.new(assistant, user: user) }
  let(:resource) { create(:scheduling_resource, account: account, name: 'Aigerim', timezone: 'Asia/Almaty', slot_duration_min: 30) }
  let(:other_resource) { create(:scheduling_resource, account: account, name: 'Dana', timezone: 'Asia/Almaty', slot_duration_min: 20) }
  let(:consultation) { create(:scheduling_service, account: account, name: 'Consultation', duration_min: 45, base_price: 20_000) }
  let(:from_time) { Time.zone.parse('2026-04-20 09:00:00 +0500') }
  let(:to_time) { Time.zone.parse('2026-04-20 12:00:00 +0500') }

  before do
    account.enable_features!('scheduling')
    create(:scheduling_work_rule, resource: resource, weekday: 1, start_minute: 9 * 60, end_minute: 18 * 60)
    create(:scheduling_work_rule, resource: other_resource, weekday: 1, start_minute: 9 * 60, end_minute: 18 * 60)
    create(:scheduling_break_rule, resource: resource, weekday: 1, start_minute: 11 * 60, end_minute: (11 * 60) + 30)
    create(:scheduling_service_price, account: account, service: consultation, resource: resource, active: true, price: 20_000)
    create(:scheduling_appointment, account: account, resource: resource, service: consultation,
                                    starts_at: Time.zone.parse('2026-04-20 10:00:00 +0500'), ends_at: Time.zone.parse('2026-04-20 10:45:00 +0500'), duration_min: 45)
  end

  describe '#execute' do
    it 'returns normalized slots using array resource_ids and service-derived duration' do
      payload = JSON.parse(
        service.execute(
          from: from_time.iso8601,
          to: to_time.iso8601,
          resource_ids: [resource.id],
          service_id: consultation.id,
          limit: 2
        )
      )

      expect(payload['service']).to include('id' => consultation.id, 'duration_min' => 45)
      expect(payload['duration_min']).to eq(45)
      expect(payload['resources'].map { |item| item['id'] }).to eq([resource.id])
      expect(payload['slots'].length).to eq(2)
      expect(payload['slots'].first).to include(
        'resource_id' => resource.id,
        'resource_name' => 'Aigerim',
        'timezone' => 'Asia/Almaty',
        'starts_at' => '2026-04-20T09:00:00+05:00',
        'ends_at' => '2026-04-20T09:45:00+05:00'
      )
      expect(payload['slots'].map { |slot| slot['starts_at'] }).not_to include('2026-04-20T10:00:00+05:00')
    end

    it 'returns an error when a requested specialist cannot perform the service' do
      result = service.execute(
        from: from_time.iso8601,
        to: to_time.iso8601,
        resource_ids: [other_resource.id],
        service_id: consultation.id
      )

      expect(result).to start_with('ERROR:')
      expect(result).to include('Service is not available for the requested specialists')
    end
  end
end
