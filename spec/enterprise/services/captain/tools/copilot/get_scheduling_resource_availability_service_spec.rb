require 'rails_helper'

RSpec.describe Captain::Tools::Copilot::GetSchedulingResourceAvailabilityService do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:service) { described_class.new(assistant, user: user) }
  let(:resource) { create(:scheduling_resource, account: account, name: 'Aigerim', timezone: 'Asia/Almaty', slot_duration_min: 30) }
  let(:consultation) { create(:scheduling_service, account: account, name: 'Consultation', duration_min: 45) }
  let(:from_time) { Time.zone.parse('2026-04-20 09:00:00 +0500') }
  let(:to_time) { Time.zone.parse('2026-04-20 12:00:00 +0500') }

  before do
    account.enable_features!('scheduling')
    create(:scheduling_work_rule, resource: resource, weekday: 1, start_minute: 9 * 60, end_minute: 18 * 60)
    create(:scheduling_break_rule, resource: resource, weekday: 1, start_minute: 11 * 60, end_minute: (11 * 60) + 30, title: 'Coffee break')
    create(:scheduling_appointment, account: account, resource: resource, service: consultation,
                                    starts_at: Time.zone.parse('2026-04-20 10:00:00 +0500'), ends_at: Time.zone.parse('2026-04-20 10:45:00 +0500'), duration_min: 45)
    create(:scheduling_service_price, account: account, service: consultation, resource: resource, active: true)
  end

  describe '#execute' do
    it 'returns specialist slots with derived duration from the service' do
      payload = JSON.parse(
        service.execute(
          resource_id: resource.id,
          from: from_time.iso8601,
          to: to_time.iso8601,
          service_id: consultation.id,
          limit: 3
        )
      )

      expect(payload['resource']['id']).to eq(resource.id)
      expect(payload['duration_min']).to eq(45)
      expect(payload['slots'].length).to eq(3)
      expect(payload['slots'].first).to include(
        'duration_min' => 45,
        'starts_at' => '2026-04-20T09:00:00+05:00',
        'ends_at' => '2026-04-20T09:45:00+05:00'
      )
      expect(payload['slots'].map { |slot| slot['starts_at'] }).not_to include('2026-04-20T10:00:00+05:00')
    end

    it 'falls back to the specialist slot duration when no service or duration is provided' do
      payload = JSON.parse(service.execute(resource_id: resource.id, from: from_time.iso8601, to: to_time.iso8601, limit: 1))

      expect(payload['duration_min']).to eq(30)
      expect(payload['slots'].first['ends_at']).to eq('2026-04-20T09:30:00+05:00')
    end

    it 'treats non-positive and blank service ids as an omitted filter' do
      [0, -1, ''].each do |service_id|
        payload = JSON.parse(
          service.execute(resource_id: resource.id, from: from_time.iso8601, to: to_time.iso8601, service_id: service_id, limit: 1)
        )

        expect(payload['service']).to be_nil
        expect(payload['duration_min']).to eq(30)
      end
    end

    it 'returns an error when the service is not available for the specialist' do
      other_service = create(:scheduling_service, account: account, name: 'Other', duration_min: 60)

      result = service.execute(resource_id: resource.id, from: from_time.iso8601, to: to_time.iso8601, service_id: other_service.id)

      expect(result).to start_with('ERROR:')
      expect(result).to include('Service is not available for this specialist')
    end
  end
end
