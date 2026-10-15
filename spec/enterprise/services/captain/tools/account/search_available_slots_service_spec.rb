require 'rails_helper'

RSpec.describe Captain::Tools::Account::SearchAvailableSlotsService do
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
                                    starts_at: Time.zone.parse('2026-04-20 10:00:00 +0500'),
                                    ends_at: Time.zone.parse('2026-04-20 10:45:00 +0500'), duration_min: 45)
  end

  describe '#execute' do
    it 'limits an agent search to its booking scope and rejects other resource IDs' do
      assistant.update!(config: assistant.config.merge('booking_scope' => { 'resource_ids' => [resource.id] }))
      service.patient_scope = Object.new
      payload = JSON.parse(service.execute(from: from_time.iso8601, to: to_time.iso8601))

      expect(payload['resources'].map { |item| item['id'] }).to eq([resource.id])
      refused = service.execute(from: from_time.iso8601, to: to_time.iso8601, resource_ids: [other_resource.id])
      expect(refused).to include('RESOURCE_UNAVAILABLE')
    end

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
      expect(payload).to include(
        'availability_scope' => 'service_confirmed',
        'requested_service_id' => consultation.id,
        'service_match' => include(
          'confirmed' => true,
          'service_id' => consultation.id,
          'resource_id' => resource.id,
          'resource_ids' => [resource.id]
        )
      )
    end

    it 'omits offer eligibility from the agent answer' do
      payload = JSON.parse(service.execute(from: from_time.iso8601, to: to_time.iso8601,
                                           resource_ids: [resource.id], service_id: consultation.id, limit: 1))

      expect(payload).not_to have_key('customer_offer_eligible')
    end

    it 'treats non-positive and blank service ids as an omitted filter' do
      [0, -1, ''].each do |service_id|
        payload = JSON.parse(
          service.execute(from: from_time.iso8601, to: to_time.iso8601, service_id: service_id, limit: 1)
        )

        expect(payload['service']).to be_nil
        expect(payload['resources'].map { |item| item['id'] }).to contain_exactly(resource.id, other_resource.id)
        expect(payload).to include(
          'availability_scope' => 'generic',
          'requested_service_id' => nil,
          'service_match' => {
            'confirmed' => false,
            'service_id' => nil,
            'resource_id' => nil,
            'resource_ids' => []
          }
        )
      end
    end

    describe 'checking one exact time' do
      def slot_starts(**arguments)
        JSON.parse(service.execute(resource_ids: [resource.id], service_id: consultation.id, **arguments))['slots'].pluck('starts_at')
      end

      it 'finds the free time named with a one-minute window' do
        expect(slot_starts(from: '2026-04-20T11:30:00+05:00', to: '2026-04-20T11:31:00+05:00', limit: 1))
          .to eq(['2026-04-20T11:30:00+05:00'])
      end

      it 'accepts a range whose end equals its start' do
        expect(slot_starts(from: '2026-04-20T11:30:00+05:00', to: '2026-04-20T11:30:00+05:00')).to eq(['2026-04-20T11:30:00+05:00'])
      end

      it 'returns no slot when that time is taken' do
        expect(slot_starts(from: '2026-04-20T10:00:00+05:00', to: '2026-04-20T10:01:00+05:00')).to eq([])
      end

      it 'rejects a range that ends before it starts' do
        result = service.execute(from: '2026-04-20T11:30:00+05:00', to: '2026-04-20T11:29:00+05:00')

        expect(result).to start_with('ERROR:')
        expect(result).to include('INVALID_DATE_RANGE')
      end
    end

    it 'ignores blank, null and zero specialist ids' do
      payload = JSON.parse(
        service.execute(from: from_time.iso8601, to: to_time.iso8601, resource_ids: ['', nil, ' ', 0, '0'], limit: 1)
      )

      expect(payload['resources'].map { |item| item['id'] }).to contain_exactly(resource.id, other_resource.id)
    end

    it 'answers a specialist name in resource_ids with a business error instead of searching every specialist' do
      result = service.execute(from: from_time.iso8601, to: to_time.iso8601, resource_ids: ['Айгерим'], limit: 1)

      expect(result).to start_with('ERROR:')
      expect(result).to include('resource_ids takes specialist IDs from search_scheduling_resources', 'INVALID_RESOURCE_IDS', 'business')
      expect(result).not_to include('INTERNAL_FAILURE')
    end

    it 'finds the starts up to the end of the range whose visit ends after it' do
      payload = JSON.parse(
        service.execute(from: '2026-04-20T12:00:00+05:00', to: '2026-04-20T13:00:00+05:00', resource_ids: [resource.id],
                        service_id: consultation.id)
      )

      expect(payload['slots'].last['starts_at']).to eq('2026-04-20T12:55:00+05:00')
      expect(payload['slots'].last['ends_at']).to eq('2026-04-20T13:40:00+05:00')
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
