# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Captain scheduling evening cutoff and past-slot guards (17.6)', type: :model do
  include ActiveSupport::Testing::TimeHelpers

  let(:account) { create(:account, reporting_timezone: 'Asia/Almaty').tap { |item| item.enable_features!('scheduling') } }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:zone) { ActiveSupport::TimeZone['Asia/Almaty'] }

  after { Current.reset }

  describe 'Item 1: evening/night run does not drop morning slots in next_available' do
    let(:resource) { create(:scheduling_resource, account: account, name: 'Кемерова А.С.', active: true) }
    let(:service_record) { create(:scheduling_service, account: account, name: 'Консультация гинеколога', duration_min: 30, active: true) }

    before do
      create(:scheduling_service_price, account: account, resource: resource, service: service_record, price: 12_000, active: true)
    end

    it 'keeps tomorrow morning slots in SearchAvailableSlotsService when run at 22:26 with #Now or date-only from' do
      travel_to(zone.local(2026, 10, 30, 22, 26, 0)) do
        tomorrow_slots = [
          { resource_id: resource.id, resource_name: resource.name, starts_at: '2026-10-31T09:00:00+05:00', ends_at: '2026-10-31T09:30:00+05:00' },
          { resource_id: resource.id, resource_name: resource.name, starts_at: '2026-10-31T10:30:00+05:00', ends_at: '2026-10-31T11:00:00+05:00' },
          { resource_id: resource.id, resource_name: resource.name, starts_at: '2026-10-31T15:00:00+05:00', ends_at: '2026-10-31T15:30:00+05:00' }
        ]
        empty_today = { total_slots: 0, slots: [], candidate_resource_ids: [resource.id], service_match: { confirmed: true } }
        lookahead_payload = { total_slots: 3, slots: tomorrow_slots, candidate_resource_ids: [resource.id], service_match: { confirmed: true } }

        call_count = 0
        allow(Scheduling::CompleteSlotSearchService).to receive(:new) do
          call_count += 1
          instance_double(Scheduling::CompleteSlotSearchService, perform: call_count.odd? ? empty_today : lookahead_payload)
        end

        tool = Captain::Tools::Account::SearchAvailableSlotsService.new(assistant, user: admin)
        tool.agent_scope = true

        %w[2026-10-30 2026-10-30T22:26:00+05:00].each do |raw_from|
          parsed = JSON.parse(
            tool.execute(from: raw_from, to: '2026-10-30T23:59:00+05:00', resource_ids: [resource.id], service_id: service_record.id)
          )
          times = parsed.dig('next_available', 0, 'times')
          expect(times).to include('09:00', '10:30', '15:00')
        end
      end
    end

    it 'still honors an explicit future afternoon preference when the patient asked for afternoon' do
      travel_to(zone.local(2026, 10, 30, 22, 26, 0)) do
        future_slots = [
          { resource_id: resource.id, resource_name: resource.name, starts_at: '2026-11-01T09:00:00+05:00', ends_at: '2026-11-01T09:30:00+05:00' },
          { resource_id: resource.id, resource_name: resource.name, starts_at: '2026-11-01T15:00:00+05:00', ends_at: '2026-11-01T15:30:00+05:00' }
        ]
        empty_day = { total_slots: 0, slots: [], candidate_resource_ids: [resource.id], service_match: { confirmed: true } }
        lookahead_payload = { total_slots: 2, slots: future_slots, candidate_resource_ids: [resource.id], service_match: { confirmed: true } }

        calls = 0
        allow(Scheduling::CompleteSlotSearchService).to receive(:new) do
          calls += 1
          instance_double(Scheduling::CompleteSlotSearchService, perform: calls == 1 ? empty_day : lookahead_payload)
        end

        tool = Captain::Tools::Account::SearchAvailableSlotsService.new(assistant, user: admin)
        tool.agent_scope = true
        parsed = JSON.parse(
          tool.execute(
            from: '2026-10-31T15:00:00+05:00',
            to: '2026-10-31T20:00:00+05:00',
            resource_ids: [resource.id],
            service_id: service_record.id
          )
        )
        expect(parsed.dig('next_available', 0, 'times')).to eq(['15:00'])
      end
    end

    it 'keeps morning slots and stays within 7-day range in SearchBookingOptionsService when from is omitted at 22:26' do
      allow(assistant).to receive(:allowed_agent_tool_ids).and_return(
        %w[search_booking_options search_available_slots search_scheduling_resources search_scheduling_services]
      )
      create(:scheduling_work_rule, resource: resource, account: account, weekday: 6, start_minute: 9 * 60, end_minute: 12 * 60)

      travel_to(zone.local(2026, 10, 30, 22, 26, 0)) do
        tool = Captain::Tools::Account::SearchBookingOptionsService.new(assistant, user: admin)
        tool.agent_scope = true

        default_range_result = JSON.parse(tool.execute(doctor: 'Кемерова'))
        expect(default_range_result.dig('range', 'from')).to start_with('2026-10-30T22:26:00')
        expect(default_range_result.dig('specialists', 'days', 0, 'times')).to include('09:00')

        tonight_only_result = JSON.parse(tool.execute(doctor: 'Кемерова', to: '2026-10-30T23:59:00+05:00'))
        expect(tonight_only_result.dig('specialists', 'next_available', 0, 'times')).to include('09:00')
      end
    end
  end

  describe 'Item 2: past slots today are excluded in Playground (real & synthetic) and MCP' do
    it 'sets agent_scope on RealToolExecutor delegates and allows search_booking_options when real_data_read is enabled' do
      allow(assistant).to receive(:allowed_agent_tool_ids).and_return(%w[search_available_slots search_booking_options])
      session = Captain::Playground::Session.new(account: account, user: admin)

      session.with_lock do |workspace|
        workspace.activate_agent!(assistant)
        workspace.set_permissions!(read: true, write: false)
        executor = Captain::Playground::RealToolExecutor.new(workspace)

        prepared_slots = executor.prepare('search_available_slots', { from: '2026-10-30T09:00:00+05:00', to: '2026-10-30T20:00:00+05:00' })
        expect(prepared_slots[:delegate].send(:agent_scope?)).to be(true)

        prepared_booking = executor.prepare('search_booking_options', { doctor: 'Кемерова' })
        expect(prepared_booking[:delegate].send(:agent_scope?)).to be(true)
        expect(executor.read?('search_booking_options')).to be(true)
      end
    end

    it 'filters out past slots today in synthetic Playground search_available_slots' do
      session = Captain::Playground::Session.new(account: account, user: admin)

      session.with_lock do |workspace|
        workspace.activate_agent!(assistant)
        appt_date = Time.iso8601(workspace.scenario.data['appointments'].first['starts_at']).in_time_zone(zone).to_date
        travel_to(zone.local(appt_date.year, appt_date.month, appt_date.day, 15, 0, 0)) do
          state = workspace.state.merge(source: 'playground', account_id: account.id, assistant_id: assistant.id)
          context = Captain::Runtime::ToolContext.new(
            run_context: Captain::Runtime::RunContext.new({ state: state, playground_session: workspace })
          )
          raw = Captain::Playground::ToolExecutor.new(workspace).execute(
            'search_available_slots',
            {
              resource_ids: [701],
              service_id: 801,
              from: zone.local(appt_date.year, appt_date.month, appt_date.day, 9, 0, 0).iso8601,
              to: zone.local(appt_date.year, appt_date.month, appt_date.day, 19, 0, 0).iso8601
            },
            context: context
          )
          parsed = raw.is_a?(String) ? JSON.parse(raw) : raw.deep_stringify_keys
          starts = Array(parsed['slots']).map { |s| Time.iso8601(s['starts_at']) }
          expect(starts).to all(be >= Time.current)
        end
      end
    end

    it 'excludes past slots by default in MCP search_available_slots while supporting include_past: true' do
      travel_to(zone.local(2026, 10, 30, 16, 0, 0)) do
        raw_slots = [
          { starts_at: '2026-10-30T09:00:00+05:00', ends_at: '2026-10-30T09:30:00+05:00', resource_id: 1 },
          { starts_at: '2026-10-30T17:00:00+05:00', ends_at: '2026-10-30T17:30:00+05:00', resource_id: 1 }
        ]
        allow(Scheduling::AvailableSlotSearchService).to receive(:new).and_return(
          instance_double(Scheduling::AvailableSlotSearchService, perform: { total_slots: 2, slots: raw_slots, service_match: { confirmed: true } })
        )

        tool = Captain::Tools::Account::SearchAvailableSlotsService.new(assistant, user: admin)
        tool.exclude_past_slots = true

        default_payload = JSON.parse(tool.execute(from: '2026-10-30T09:00:00+05:00', to: '2026-10-30T20:00:00+05:00'))
        expect(default_payload['total_slots']).to eq(1)
        expect(default_payload['slots'].pluck('starts_at')).to eq(['2026-10-30T17:00:00+05:00'])

        audit_payload = JSON.parse(tool.execute(from: '2026-10-30T09:00:00+05:00', to: '2026-10-30T20:00:00+05:00', include_past: true))
        expect(audit_payload['total_slots']).to eq(2)
      end
    end

    it 'excludes past slots in MCP get_scheduling_resource_availability when exclude_past_slots is true' do
      resource = create(:scheduling_resource, account: account, name: 'Врач УЗИ', timezone: 'Asia/Almaty', active: true)
      create(:scheduling_work_rule, resource: resource, account: account, weekday: 5, start_minute: 9 * 60, end_minute: 19 * 60)

      travel_to(zone.local(2026, 10, 30, 16, 0, 0)) do
        tool = Captain::Tools::Account::GetSchedulingResourceAvailabilityService.new(assistant, user: admin)
        tool.exclude_past_slots = true

        payload = JSON.parse(
          tool.execute(resource_id: resource.id, from: '2026-10-30T09:00:00+05:00', to: '2026-10-30T19:00:00+05:00')
        )
        starts = Array(payload['slots']).map { |s| Time.iso8601(s['starts_at']) }
        expect(starts).not_to be_empty
        expect(starts).to all(be >= Time.current)
      end
    end
  end
end
