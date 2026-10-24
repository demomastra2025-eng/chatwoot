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

      expect(payload['slots'].last['starts_at']).to eq('2026-04-20T12:30:00+05:00')
      expect(payload['slots'].last['ends_at']).to eq('2026-04-20T13:15:00+05:00')
    end

    it 'searches a requested specialist with a service that is not linked to them, with the service duration' do
      payload = JSON.parse(service.execute(from: from_time.iso8601, to: to_time.iso8601, resource_ids: [other_resource.id],
                                           service_id: consultation.id, limit: 1))

      expect(payload['slots'].first).to include('resource_id' => other_resource.id, 'starts_at' => '2026-04-20T09:00:00+05:00',
                                                'ends_at' => '2026-04-20T09:45:00+05:00')
      expect(payload).to include('service_link_status' => 'price_link_unverified', 'availability_scope' => 'service_unconfirmed')
    end
  end

  describe 'with no service-price links in the account' do
    let(:conversation) { create(:conversation, account: account) }

    before { Scheduling::ServicePrice.where(account_id: account.id).delete_all }

    def execute(**arguments)
      service.execute(from: from_time.iso8601, to: to_time.iso8601, **arguments)
    end

    it 'searches the requested specialist with the service' do
      payload = JSON.parse(execute(resource_ids: [resource.id], service_id: consultation.id, limit: 2))

      expect(payload['total_slots']).to eq(2)
      expect(payload['duration_min']).to eq(45)
      expect(payload['candidate_resource_ids']).to eq([resource.id])
      expect(payload['service_link_status']).to eq('price_link_unverified')
    end

    it 'asks to choose the specialist first instead of searching every specialist for the service' do
      result = execute(service_id: consultation.id)

      expect(result).to start_with('ERROR:')
      expect(result).to include('Choose the specialist first', 'search_scheduling_resources', 'resource_ids', 'RESOURCE_REQUIRED')
      expect(result).not_to match(/\p{Cyrillic}/)
      expect(Captain::Runtime::ToolFailure.describe(result)).to include(retryable: true, code: 'resource_required')
      expect(Captain::Runtime::ToolFailure.classify(result)).to eq('business')
    end

    it 'gives the agent the same answer and infers no service from links when only specialists are given' do
      service.patient_scope = Captain::Tools::Agent::PatientScope.new(assistant: assistant, conversation: conversation)
      travel_to(Time.zone.parse('2026-04-19 12:00:00 +0500')) do
        expect(execute(service_id: consultation.id)).to include('RESOURCE_REQUIRED')

        payload = JSON.parse(execute(resource_ids: [resource.id], limit: 1))
        expect(payload).not_to include('service', 'service_id')
        expect(payload['duration_min']).to eq(30)
        expect(payload['days']).to eq([{ 'resource_id' => resource.id, 'name' => 'Aigerim', 'date' => '2026-04-20',
                                         'times' => %w[09:00 09:30 11:30], 'more' => 0 }])
        expect(payload).to include('total' => 3)
      end
    end
  end
end
