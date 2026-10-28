require 'rails_helper'

RSpec.describe Captain::Tools::Account::GetSchedulingResourceAvailabilityService do
  include ActiveSupport::Testing::TimeHelpers

  around { |example| travel_to(Time.utc(2026, 4, 19, 12)) { example.run } }

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
                                    starts_at: Time.zone.parse('2026-04-20 10:00:00 +0500'),
                                    ends_at: Time.zone.parse('2026-04-20 10:45:00 +0500'), duration_min: 45)
    create(:scheduling_service_price, account: account, service: consultation, resource: resource, active: true)
  end

  describe '#execute' do
    it 'returns specialist slots with derived duration from the service' do
      payload = JSON.parse(
        service.execute(
          resource_id: resource.id,
          from: from_time.iso8601,
          to: (to_time + 2.hours).iso8601,
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
      # The 30-minute grid of the specialist: 09:30 and 10:00 would run into the visit of 10:00, 11:00 into the break.
      expect(payload['slots'].map { |slot| slot['starts_at'] }).to eq(
        %w[2026-04-20T09:00:00+05:00 2026-04-20T11:30:00+05:00 2026-04-20T12:00:00+05:00]
      )
      expect(payload).not_to have_key('customer_offer_eligible')
    end

    it 'falls back to the specialist slot duration when no service or duration is provided' do
      payload = JSON.parse(service.execute(resource_id: resource.id, from: from_time.iso8601, to: to_time.iso8601, limit: 1))

      expect(payload['duration_min']).to eq(30)
      expect(payload['slots'].first['ends_at']).to eq('2026-04-20T09:30:00+05:00')
    end

    it 'includes the specialist absence reason and last day even with provider hours' do
      resource.update!(custom_attributes: { 'medelement_specialist_code' => 'provider-123' })
      zone = Time.find_zone!('Asia/Almaty')
      create(:scheduling_time_off, account: account, resource: resource, kind: 'vacation',
                                   starts_at: zone.local(2026, 4, 20), ends_at: zone.local(2026, 4, 23), notes: 'Annual leave')

      payload = JSON.parse(service.execute(resource_id: resource.id, from: from_time.iso8601, to: to_time.iso8601))

      expect(payload['absences']).to include(include('kind' => 'vacation', 'through' => '2026-04-22', 'reason' => 'Annual leave'))
    end

    it 'does not return local windows for a provider specialist when provider access is unavailable' do
      resource.update!(custom_attributes: { 'medelement_specialist_code' => 'provider-123' })

      payload = JSON.parse(service.execute(resource_id: resource.id, from: from_time.iso8601, to: to_time.iso8601,
                                           service_id: consultation.id, limit: 1))

      expect(payload).to include('availability_source' => 'medelement', 'provider_checked' => false,
                                 'provider_required' => true, 'service_link_status' => 'price_link_unverified')
      expect(payload['slots']).to be_empty
    end

    it 'flags diagnostic resources with provider cabinets but no personal specialist code' do
      resource.update!(custom_attributes: { 'medelement_cabinets' => [{ 'cabinetCode' => 'room-1' }] })

      payload = JSON.parse(service.execute(resource_id: resource.id, from: from_time.iso8601, to: to_time.iso8601,
                                           service_id: consultation.id, limit: 1))

      expect(payload).to include('provider_required' => true, 'provider_checked' => false,
                                 'service_link_status' => 'price_link_unverified')
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

    it 'returns the windows for a service with no link to the specialist, with the service duration' do
      other_service = create(:scheduling_service, account: account, name: 'Other', duration_min: 60)

      payload = JSON.parse(service.execute(resource_id: resource.id, from: from_time.iso8601, to: to_time.iso8601,
                                           service_id: other_service.id, limit: 1))

      expect(payload['duration_min']).to eq(60)
      expect(payload['slots'].first['ends_at']).to eq('2026-04-20T10:00:00+05:00')
      expect(payload).to include('service_link_status' => 'price_link_unverified', 'provider_required' => false)
    end

    it 'returns the windows with the service when the account has no service-price links at all' do
      Scheduling::ServicePrice.where(account_id: account.id).delete_all

      payload = JSON.parse(service.execute(resource_id: resource.id, from: from_time.iso8601, to: to_time.iso8601,
                                           service_id: consultation.id, limit: 1))

      expect(payload['service']).to include('id' => consultation.id)
      expect(payload['slots']).to be_present
      expect(payload['service_link_status']).to eq('price_link_unverified')
    end
  end
end
