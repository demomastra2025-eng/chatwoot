require 'rails_helper'

RSpec.describe Captain::Playground::AvailabilitySnapshot do
  let(:zone) { Time.find_zone!('Asia/Almaty') }
  let(:day) { Date.new(2026, 10, 12) }
  let(:from) { zone.local(day.year, day.month, day.day, 0) }
  let(:to) { from + 1.day }
  let(:resource) do
    { 'id' => 701, 'name' => 'Scenario specialist', 'timezone' => 'Asia/Almaty', 'active' => true,
      'service_ids' => [801], 'work_rules' => [{ 'weekday' => day.wday, 'start_minute' => 600, 'end_minute' => 960 }],
      'break_rules' => [{ 'weekday' => day.wday, 'start_minute' => 720, 'end_minute' => 780 }],
      'holidays' => [], 'workday_overrides' => [],
      'time_offs' => [{ 'id' => 1801, 'starts_at' => (from + 14.hours).iso8601, 'ends_at' => (from + 15.hours).iso8601 }] }
  end
  let(:appointments) do
    [{ 'id' => 601, 'resource_id' => 701, 'status' => 'scheduled', 'starts_at' => (from + 11.hours).iso8601,
       'ends_at' => (from + 11.hours + 30.minutes).iso8601, 'custom_attributes' => {} }]
  end

  def native_engine
    native = Scheduling::Resource.new(id: 701, name: resource['name'], timezone: resource['timezone'])
    work = described_class::Rules.new(resource['work_rules'].map { |rule| Scheduling::WorkRule.new(rule) })
    breaks = described_class::Rules.new(resource['break_rules'].map { |rule| Scheduling::BreakRule.new(rule) })
    native.define_singleton_method(:work_rules) { work }
    native.define_singleton_method(:break_rules) { breaks }
    Scheduling::AvailabilityService.new(resource: native, from: from, to: to,
      holidays: resource['holidays'].map { |item| Scheduling::Holiday.new(item) },
      workday_overrides: resource['workday_overrides'].map { |item| Scheduling::WorkdayOverride.new(item) },
      time_offs: resource['time_offs'].map { |item| Scheduling::TimeOff.new(item) },
      appointments: appointments.map { |item| Scheduling::Appointment.new(item) })
  end

  def snapshot_engine
    described_class.build(resource: resource, appointments: appointments, from: from, to: to)
  end

  def slot_instants(engine)
    engine.slots(duration_min: 30).map do |slot|
      slot.merge(starts_at: Time.iso8601(slot.fetch(:starts_at)), ends_at: Time.iso8601(slot.fetch(:ends_at)))
    end
  end

  it 'returns identical native errors and slots for configured hours, breaks, time off, collisions and invalid intervals' do
    { 9 => 'OUTSIDE_WORKING_HOURS', 10 => nil, 11 => 'SLOT_CONFLICT', 12 => 'BLOCKED_BY_BREAK',
      14 => 'BLOCKED_BY_VACATION', 16 => 'OUTSIDE_WORKING_HOURS' }.each do |hour, code|
      arguments = { starts_at: from + hour.hours, ends_at: from + hour.hours + 30.minutes }
      expected = native_engine.availability_result(**arguments)
      actual = snapshot_engine.availability_result(**arguments)
      expect(actual.to_h).to eq(expected.to_h)
      expect(actual.code).to eq(code)
    end
    expect(snapshot_engine.availability_result(starts_at: from, ends_at: from).to_h)
      .to eq(native_engine.availability_result(starts_at: from, ends_at: from).to_h)
    expect(slot_instants(snapshot_engine)).to eq(slot_instants(native_engine))
    expect(snapshot_engine.slots(duration_min: 30).first[:starts_at]).to eq((from + 10.hours).iso8601)
  end

  it 'preserves native holiday and workday-override semantics rather than a fixed default calendar' do
    resource['holidays'] = [{ 'date' => day.iso8601, 'title' => 'Closed day', 'recurring_yearly' => false, 'working_day_override' => false }]
    arguments = { starts_at: from + 10.hours, ends_at: from + 10.hours + 30.minutes }
    expect(snapshot_engine.availability_result(**arguments).code).to eq('BLOCKED_BY_HOLIDAY')
    expect(snapshot_engine.free_intervals).to eq(native_engine.free_intervals)
    resource['workday_overrides'] = [{ 'date' => day.iso8601, 'start_minute' => 600, 'end_minute' => 720 }]
    expect(snapshot_engine.availability_result(**arguments).to_h).to eq(native_engine.availability_result(**arguments).to_h)
    expect(slot_instants(snapshot_engine)).to eq(slot_instants(native_engine))
  end

  it 'returns the native availability envelope through the real schema with negative session IDs and no real schedule reads' do
    account = create(:account).tap { |item| item.enable_features!('scheduling') }
    user = create(:user, :administrator, account: account)
    assistant = create(:captain_assistant, account: account)
    allow(assistant).to receive(:allowed_agent_tool_ids).and_return(%w[get_scheduling_resource_availability])
    allow(Captain::ToolSafety).to receive(:check_arguments!)
    allow(Captain::ToolSafety).to receive(:check_result!)
    expect(account).not_to receive(:scheduling_resources)
    expect(Scheduling::Resource).not_to receive(:find)
    session = Captain::Playground::Session.new(account: account, user: user, assistant: assistant)
    session.with_lock do |workspace|
      workspace.scenario.data['resources'][0] = resource.deep_dup
      workspace.scenario.data['appointments'][0].merge!(appointments.first)
      workspace.set_permissions!(read: true, write: false)
      definition = Captain::ToolRegistry.definition_for('get_scheduling_resource_availability')
      tool = definition.agent_tool_class.new(assistant, tool_id: definition.id)
      context = Captain::Runtime::RunContext.new({ state: workspace.state.merge(source: 'playground', account_id: account.id,
        assistant_id: assistant.id), playground_session: workspace })
      wrapper = Captain::Runtime::ToolWrapper.new(tool, context)
      resource_id = workspace.namespace.encode({ resource_id: 701 })[:resource_id]
      payload = JSON.parse(wrapper.call(resource_id: resource_id, from: from.iso8601, to: to.iso8601, duration_min: 30))
      expect(payload).to include('simulated' => true, 'duration_min' => 30, 'timezone' => 'Asia/Almaty', 'provider_checked' => false)
      expect(payload['slots']).not_to be_empty
      expect(payload['slots'].first['resource_id']).to eq(resource_id)
      expect(payload['slots'].first['starts_at']).to eq((from + 10.hours).iso8601)
      expect(wrapper.call(resource_id: resource_id, from: to.iso8601, to: from.iso8601))
        .to include('to must be greater than from')
    end
  ensure
    Current.reset
  end
end
