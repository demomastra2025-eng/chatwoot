require 'rails_helper'

# The patient agent gets every free start of the range grouped by specialist and day (Captain::Tools::Agent::SlotsPayload);
# staff and Copilot keep the payload with the slots one by one. All data is synthetic.
RSpec.describe Captain::Tools::Account::SearchAvailableSlotsService do
  include ActiveSupport::Testing::TimeHelpers

  let(:now) { Time.zone.parse('2026-04-19 12:00:00 +0500') }
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:inbox) { create(:inbox, account: account, timezone: 'Asia/Almaty') }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }
  let(:agent_tool) do
    described_class.new(assistant, user: assistant, conversation: conversation).tap do |tool|
      tool.patient_scope = Captain::Tools::Agent::PatientScope.new(assistant: assistant, conversation: conversation)
    end
  end
  let(:staff_tool) { described_class.new(assistant, user: user) }
  let(:consultation) { create(:scheduling_service, account: account, name: 'Consultation', duration_min: 20, base_price: 20_000) }
  # 2026-04-20 is a Monday; both specialists work 08:00-20:00 on Monday to Wednesday, 10 minutes apart: a visit of 20 minutes
  # starts 71 times a day (08:00 ... 19:40).
  let(:aigerim) { create(:scheduling_resource, account: account, name: 'Aigerim', timezone: 'Asia/Almaty', slot_duration_min: 10) }
  let(:dana) { create(:scheduling_resource, account: account, name: 'Dana', timezone: 'Asia/Almaty', slot_duration_min: 10) }

  around { |example| travel_to(now) { example.run } }

  before do
    account.enable_features!('scheduling')
    [aigerim, dana].each do |resource|
      (1..3).each do |weekday|
        create(:scheduling_work_rule, resource: resource, account: account, weekday: weekday, start_minute: 8 * 60, end_minute: 20 * 60)
      end
      create(:scheduling_service_price, account: account, service: consultation, resource: resource, active: true, price: 20_000)
    end
  end

  def search(tool, **arguments)
    tool.execute(from: '2026-04-20', to: '2026-04-23', service_id: consultation.id, **arguments)
  end

  def build_diagnostic_cabinets
    ct_cabinet = create(:scheduling_resource, account: account, name: 'CT Cabinet', timezone: 'Asia/Almaty', slot_duration_min: 15)
    mri_cabinet = create(:scheduling_resource, account: account, name: 'MRI Cabinet', timezone: 'Asia/Almaty', slot_duration_min: 30)
    ct_service = create(:scheduling_service, account: account, name: 'CT Head', duration_min: 15)
    mri_service = create(:scheduling_service, account: account, name: 'MRI Head', duration_min: 30)
    [ct_cabinet, mri_cabinet].each do |cab|
      create(:scheduling_work_rule, resource: cab, account: account, weekday: 1, start_minute: 9 * 60, end_minute: 18 * 60)
    end
    create(:scheduling_resource_service_stat, account: account, resource: ct_cabinet, service: ct_service,
                                              status: 'auto', receptions_count: 20, median_duration_min: 15)
    create(:scheduling_resource_service_stat, account: account, resource: mri_cabinet, service: mri_service,
                                              status: 'auto', receptions_count: 35, median_duration_min: 30)
    [ct_cabinet, mri_cabinet, mri_service]
  end

  describe 'for the patient agent' do
    it 'groups the starts by specialist and day with five spread times and the count of the rest' do
      answer = JSON.parse(search(agent_tool, resource_ids: [aigerim.id]))

      expect(answer).to include('service_id' => consultation.id, 'duration_min' => 20)
      expect(answer['days'].pluck('date')).to eq(%w[2026-04-20 2026-04-21 2026-04-22])
      day = answer['days'].first
      expect(day).to include('resource_id' => aigerim.id, 'name' => 'Aigerim', 'more' => 66)
      expect(day['times'].size).to eq(5)
      expect(day['times'].first).to eq('08:00')
      expect(day['times'].count { |time| time >= '12:00' }).to be >= 2
    end

    it 'does not cut a day short at the cap of the full payload' do
      answer = JSON.parse(search(agent_tool, resource_ids: [aigerim.id, dana.id]))

      # 2 specialists x 3 days x 71 starts: far over the 100 starts of the full payload
      expect(answer['total']).to eq(426)
      expect(answer['days'].sum { |day| day['times'].size + day['more'] }).to eq(426)
      expect(answer['days'].pluck('more').uniq).to eq([66])
    end

    it 'carries no per-slot fields, no service card and no resource cards' do
      text = search(agent_tool, resource_ids: [aigerim.id])

      expect(text).not_to match(/starts_at|ends_at|timezone|cabinet|"resources"|"service"|availability_scope|service_match/)
      expect(text.scan('Aigerim').size).to eq(3)
      expect(text).not_to include("\n")
    end

    it 'books with the date and a listed time' do
      day = JSON.parse(search(agent_tool, resource_ids: [aigerim.id]))['days'].first

      zone = ActiveSupport::TimeZone[aigerim.timezone]

      expect(Captain::Tools::Agent::AppointmentTimeInput.parse("#{day['date']}T#{day['times'].first}", timezone: zone, field_name: 'starts_at'))
        .to eq(zone.local(2026, 4, 20, 8))
    end

    it 'takes limit as the number of specialist-days and says how many were left out' do
      answer = JSON.parse(search(agent_tool, resource_ids: [aigerim.id, dana.id], limit: 4))

      expect(answer['days'].size).to eq(4)
      expect(answer['more_days']).to eq(2)
      expect(answer['total']).to eq(426)
    end

    it 'answers an empty day with the nearest days that have free time' do
      Scheduling::WorkRule.where(resource_id: aigerim.id, weekday: 1).delete_all
      Scheduling::WorkRule.where(resource_id: aigerim.id, weekday: 3).delete_all

      answer = JSON.parse(agent_tool.execute(from: '2026-04-20', to: '2026-04-21', resource_ids: [aigerim.id], service_id: consultation.id))

      expect(answer).to include('total' => 0, 'days' => [], 'requested_range_status' => 'no_reception_scheduled')
      expect(answer['requested_range_note']).to include('next_available')
      expect(answer['next_available'].first).to include('date' => '2026-04-21', 'resource_id' => aigerim.id)
      expect(answer['next_available'].size).to eq(1)
    end

    context 'when it is late on the day of the search' do
      let(:now) { Time.zone.parse('2026-04-20 17:30:00 +0500') }

      it 'does not offer a time that has passed' do
        answer = JSON.parse(agent_tool.execute(from: '2026-04-20', to: '2026-04-21', resource_ids: [aigerim.id], service_id: consultation.id))

        expect(answer['days'].first['times']).to all(be >= '17:30')
      end
    end

    it 'is a fraction of the size of the full payload on the same search' do
      arguments = { resource_ids: [aigerim.id, dana.id] }
      before = search(staff_tool, **arguments).bytesize
      after = search(agent_tool, **arguments).bytesize

      expect(JSON.parse(search(staff_tool, **arguments))['slots'].size).to eq(100)
      expect(after).to be < before / 25
    end

    it 'rejects a mismatched resource_ids with retryable SERVICE_RESOURCE_MISMATCH and eligible_resources' do
      ct_cabinet, mri_cabinet, mri_service = build_diagnostic_cabinets
      result = agent_tool.execute(from: '2026-04-20', to: '2026-04-21', resource_ids: [ct_cabinet.id], service_id: mri_service.id)

      expect(result).to start_with('ERROR:')
      expect(result).to include('SERVICE_RESOURCE_MISMATCH', 'service_resource_mismatch', 'MRI Cabinet')
      expect(Captain::Runtime::ToolFailure.describe(result)).to include(failure: true, retryable: true)
      expect(Captain::Runtime::ToolFailure.classify(result)).to eq('business')
      expect(Captain::Runtime::ToolFailure.facts(result).dig('details', 'eligible_resources'))
        .to eq([{ 'id' => mri_cabinet.id, 'name' => 'MRI Cabinet' }])
    end

    it 'filters out incompatible indexed specialists when a multi-resource request includes a compatible one' do
      ct_cabinet, mri_cabinet, mri_service = build_diagnostic_cabinets
      answer = JSON.parse(
        agent_tool.execute(from: '2026-04-20', to: '2026-04-21', resource_ids: [ct_cabinet.id, mri_cabinet.id], service_id: mri_service.id)
      )

      expect(answer['days'].pluck('resource_id').uniq).to eq([mri_cabinet.id])
    end

    it 'allows an unindexed specialist with zero recorded services even when the service has ServicePrice links on others' do
      new_doctor = create(:scheduling_resource, account: account, name: 'New Neurologist', timezone: 'Asia/Almaty', slot_duration_min: 30)
      create(:scheduling_work_rule, resource: new_doctor, account: account, weekday: 1, start_minute: 9 * 60, end_minute: 12 * 60)

      answer = JSON.parse(
        agent_tool.execute(from: '2026-04-20', to: '2026-04-21', resource_ids: [new_doctor.id], service_id: consultation.id)
      )
      expect(answer['total']).to be > 0
      expect(answer['days'].first['resource_id']).to eq(new_doctor.id)

      create(:scheduling_service_price, account: account, service: consultation, resource: new_doctor, active: false, price: 20_000)
      rejected = agent_tool.execute(from: '2026-04-20', to: '2026-04-21', resource_ids: [new_doctor.id], service_id: consultation.id)
      expect(rejected).to include('SERVICE_RESOURCE_MISMATCH')
    end
  end

  describe 'for staff' do
    it 'keeps the payload with the slots one by one, cut at the limit' do
      payload = JSON.parse(search(staff_tool, resource_ids: [aigerim.id], limit: 3))

      expect(payload['slots'].size).to eq(3)
      expect(payload['slots'].first).to include('resource_id' => aigerim.id, 'resource_name' => 'Aigerim', 'timezone' => 'Asia/Almaty',
                                                'starts_at' => '2026-04-20T08:00:00+05:00')
      expect(payload).to include('service', 'resources', 'total_slots' => 3, 'slot_count_scope' => 'returned_only')
      expect(payload).not_to include('days', 'total')
    end

    it 'still cuts the list at 100 starts' do
      payload = JSON.parse(search(staff_tool, resource_ids: [aigerim.id, dana.id]))

      expect(payload['slots'].size).to eq(100)
    end
  end
end
