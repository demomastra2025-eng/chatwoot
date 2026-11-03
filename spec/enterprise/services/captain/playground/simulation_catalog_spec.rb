require 'rails_helper'

RSpec.describe Captain::Playground::SimulationCatalog do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account, role: :administrator) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:session) { Captain::Playground::Session.new(account: account, user: user) }
  let(:resource) { create(:scheduling_resource, account: account, name: 'Catalogue specialist') }
  let(:service) { create(:scheduling_service, account: account) }
  let(:starts_at) { 2.days.from_now.in_time_zone('Asia/Almaty').change(hour: 10, min: 0, sec: 0) }
  let(:patient) { { first_name: 'Тимур', last_name: 'Садыков', iin: '150101500011' } }

  before do
    account.enable_features!('scheduling')
    allow(Captain::ToolSafety).to receive(:check_arguments!)
    allow(Captain::ToolSafety).to receive(:check_result!)
    selected_tools = %w[
      create_appointment update_appointment cancel_appointment get_appointment search_scheduling_resources
      search_available_slots get_scheduling_resource_availability search_booking_options
    ]
    allow(assistant).to receive(:allowed_agent_tool_ids).and_return(selected_tools)
    create(:scheduling_work_rule, resource: resource, weekday: starts_at.wday, start_minute: 0, end_minute: 1440)
    create(:scheduling_service_price, resource: resource, service: service)
  end

  after { Current.reset }

  def call(workspace, id, arguments)
    definition = Captain::ToolRegistry.definition_for(id)
    tool = if definition.agent_tool_class == Captain::Tools::Agent::AccountToolAdapter
             definition.agent_tool_class.new(assistant, tool_id: id)
           else
             definition.agent_tool_class.new(assistant)
           end
    state = workspace.state.merge(source: 'playground', account_id: account.id, assistant_id: assistant.id)
    context = Captain::Runtime::RunContext.new({ state: state, playground_session: workspace })
    result = Captain::Runtime::ToolWrapper.new(tool, context).call(**arguments)
    return { 'success' => false, 'error' => result } if result.start_with?('ERROR:')

    JSON.parse(result)
  end

  def booking_arguments
    { resource_id: resource.id, service_id: service.id, starts_at: starts_at.iso8601 }
  end

  def business_counts
    [Contact, Conversation, Message, Scheduling::Appointment, Integrations::Medelement::ProviderCommand].map(&:count)
  end

  def stub_provider_slots
    result = Scheduling::ScheduleDayAvailabilityService::Result.new(
      slots: [{ resource_id: resource.id, starts_at: starts_at.iso8601, ends_at: (starts_at + 20.minutes).iso8601,
                duration_min: 20, status: 'available' }],
      state: 'ok', checked_at: Time.current, source: 'provider_schedule', last_bookable_date: nil
    )
    provider = instance_double(Scheduling::ScheduleDayAvailabilityService, perform: result)
    allow(Scheduling::ScheduleDayAvailabilityService).to receive(:new).and_return(provider)
    expect(Integrations::Medelement::ResourceAvailabilityService).not_to receive(:new)
  end

  def interleave_availability_read
    klass = Captain::Tools::Account::GetSchedulingResourceAvailabilityService
    allow(klass).to receive(:new).and_wrap_original do |constructor, *args, **kwargs|
      delegate = constructor.call(*args, **kwargs)
      execute = delegate.method(:execute)
      execute = execute.super_method if execute.owner == Captain::Tools::Instrumentation
      allow(delegate).to receive(:execute) do |**arguments|
        result = execute.call(**arguments)
        yield
        result
      end
      delegate
    end
  end

  it 'reads the real catalogue then creates, moves and cancels only a session-owned appointment', :aggregate_failures do
    session.with_lock do |workspace|
      workspace.activate_agent!(assistant)
      workspace.set_permissions!(read: true, write: false)
      initial = business_counts
      expect(Scheduling::Appointments::UpsertService).not_to receive(:new)
      expect(Outbound::MessageSender).not_to receive(:new) if defined?(Outbound::MessageSender)
      catalogue = call(workspace, 'search_scheduling_resources', query: resource.name)
      expect(catalogue.to_json).to include(resource.name)
      expect(catalogue.dig('resources', 0, 'id')).to eq(resource.id)
      created = call(workspace, 'create_appointment', booking_arguments)
      expect(created).to include('success' => true, 'simulated' => true, 'status' => 'created')
      expect(created['appointment_id']).to be_negative
      expect(created.dig('appointment', 'resource_id')).to be_negative
      expect(created.dig('appointment', 'patient_contact_id')).to eq(workspace.namespace.encode({ id: 101 })[:id])
      expect(call(workspace, 'create_appointment', booking_arguments)).to include('success' => false, 'reason' => 'time_taken')
      moved = call(workspace, 'update_appointment', appointment_id: created['appointment_id'], starts_at: (starts_at + 1.hour).iso8601)
      expect(moved).to include('success' => true, 'status' => 'updated')
      expect(call(workspace, 'cancel_appointment', appointment_id: created['appointment_id']))
        .to include('success' => true, 'status' => 'cancelled')
      expect(workspace.payload[:action_previews]).to be_empty
      expect(business_counts).to eq(initial)
    end
  end

  it 'simulates a new patient without a real card and never looks up a real patient binding' do
    session.with_lock do |workspace|
      workspace.activate_agent!(assistant)
      workspace.set_permissions!(read: true, write: false)
      expect(Integrations::Medelement::PatientContactBinding).not_to receive(:recorded_contact_by_iin)
      initial = business_counts
      created = call(workspace, 'create_appointment', booking_arguments.merge(patient: { first_name: 'Synthetic', last_name: 'New' }))
      expect(created).to include('success' => true, 'simulated' => true)
      expect(created.dig('appointment', 'patient_contact_id')).to be_negative
      expect(business_counts).to eq(initial)
    end
  end

  it 'keeps a supplied patient synthetic and requires exact confirmation for a different patient when changing the booking' do
    session.with_lock do |workspace|
      workspace.activate_agent!(assistant)
      workspace.set_permissions!(read: true, write: false)
      initial = business_counts
      created = call(workspace, 'create_appointment', booking_arguments.merge(patient: patient))
      expect(created).to include('success' => true, 'simulated' => true)
      expect(created.dig('appointment', 'patient_contact_id')).to be_negative
      denied = call(workspace, 'update_appointment', appointment_id: created['appointment_id'], starts_at: (starts_at + 1.hour).iso8601)
      expect(denied['success']).to be(false)
      moved = call(workspace, 'update_appointment', appointment_id: created['appointment_id'],
                                                    appointment_access_token: created['appointment_access_token'], patient_confirmed: true,
                                                    starts_at: (starts_at + 1.hour).iso8601)
      expect(moved['success']).to be(true)
      workspace.set_permissions!(read: true, write: true)
      expect { Captain::Playground::ActionApproval.new(workspace).preview('create_appointment', booking_arguments.merge(patient: patient)) }
        .to raise_error(ArgumentError, /Synthetic patients cannot be promoted/)
      expect(business_counts).to eq(initial)
    end
  end

  it 'does not convert missing or foreign real references into successful simulated bookings' do
    foreign = create(:scheduling_resource)
    session.with_lock do |workspace|
      workspace.activate_agent!(assistant)
      workspace.set_permissions!(read: true, write: false)
      initial = workspace.scenario.data['appointments'].deep_dup
      [foreign.id, 2_000_000_000].each do |id|
        expect(call(workspace, 'create_appointment', booking_arguments.merge(resource_id: id))['success']).to be(false)
      end
      expect(workspace.scenario.data['appointments']).to eq(initial)
    end
  end

  it 'keeps distinct catalogue services and preserves the earlier simulated appointment snapshot' do
    other_service = create(:scheduling_service, account: account)
    create(:scheduling_service_price, resource: resource, service: other_service)
    session.with_lock do |workspace|
      workspace.activate_agent!(assistant)
      workspace.set_permissions!(read: true, write: false)
      first = call(workspace, 'create_appointment', booking_arguments)
      second = call(workspace, 'create_appointment', booking_arguments.merge(service_id: other_service.id, starts_at: (starts_at + 1.hour).iso8601))
      expect(first['success']).to be(true)
      expect(second['success']).to be(true)
      expect(second.dig('appointment', 'service_id')).not_to eq(first.dig('appointment', 'service_id'))
      expect(call(workspace, 'get_appointment', appointment_id: first['appointment_id'])['success']).to be(true)
    end
  end

  it 'requires a fresh session-owned provider slot and rechecks a removed catalogue link' do
    resource.update!(custom_attributes: { medelement_specialist_code: 'synthetic-provider' })
    session.with_lock do |workspace|
      workspace.activate_agent!(assistant)
      workspace.set_permissions!(read: true, write: false)
      expect(call(workspace, 'create_appointment', booking_arguments)['success']).to be(false)
      offers = Captain::Playground::SchedulingOffers.new(workspace)
      provenance = offers.begin_read('search_available_slots', booking_arguments)
      offers.record(
        'search_available_slots',
        { slots: [booking_arguments.merge(ends_at: (starts_at + 30.minutes).iso8601)] }.deep_stringify_keys, {}, provenance: provenance
      )
      created = call(workspace, 'create_appointment', booking_arguments)
      expect(created['success']).to be(true)
      workspace.data['catalog_slots'].each { |slot| slot['expires_at'] = 1.minute.ago.to_i }
      expect(call(workspace, 'update_appointment', appointment_id: created['appointment_id'])['success']).to be(false)
      resource.service_prices.find_each { |price| price.update!(active: false) }
      expect(call(workspace, 'create_appointment', booking_arguments)['success']).to be(false)
    end
  end

  %w[mapping permissions].each do |change|
    it "rejects an actual delegate result whose #{change} changed while the real read was in flight" do
      resource.update!(custom_attributes: { medelement_specialist_code: 'mapping-A' })
      stub_provider_slots
      session.with_lock do |workspace|
        workspace.activate_agent!(assistant)
        workspace.set_permissions!(read: true, write: false)
        interleave_availability_read do
          if change == 'mapping'
            # An external editor is outside the delegate's read-only connection.
            ActiveRecord::Base.connected_to(role: :writing, prevent_writes: false) do
              resource.update!(custom_attributes: { medelement_specialist_code: 'mapping-B' })
            end
          else
            workspace.set_permissions!(read: false, write: false)
            workspace.set_permissions!(read: true, write: false)
          end
        end
        range = { resource_id: resource.id, service_id: service.id, from: (starts_at - 1.hour).iso8601, to: (starts_at + 1.hour).iso8601 }
        expect(call(workspace, 'get_scheduling_resource_availability', range).fetch('slots')).to be_present
        expect(Array(workspace.data['catalog_slots'])).to be_empty
        expect(call(workspace, 'create_appointment', booking_arguments)['success']).to be(false)
      end
    end
  end

  it 'keeps a delegate offer valid after unrelated sync metadata and timestamp updates during the read' do
    resource.update!(custom_attributes: { medelement_specialist_code: 'mapping-A' })
    stub_provider_slots
    interleave_availability_read do
      ActiveRecord::Base.connected_to(role: :writing, prevent_writes: false) do
        resource.update!(custom_attributes: resource.custom_attributes.merge('last_sync_at' => Time.current.iso8601))
        service.update!(description: 'Synthetic sync metadata')
      end
    end
    session.with_lock do |workspace|
      workspace.activate_agent!(assistant)
      workspace.set_permissions!(read: true, write: false)
      range = { resource_id: resource.id, service_id: service.id, from: (starts_at - 1.hour).iso8601, to: (starts_at + 1.hour).iso8601 }
      call(workspace, 'get_scheduling_resource_availability', range)
      expect(workspace.data['catalog_slots']).to be_present
      expect(call(workspace, 'create_appointment', booking_arguments)['success']).to be(true)
    end
  end

  %w[search_available_slots get_scheduling_resource_availability search_booking_options].each do |read_tool|
    it "simulates a provider booking from the actual #{read_tool} formatter and preserves its offered duration" do
      resource.update!(custom_attributes: { medelement_specialist_code: 'synthetic-provider' })
      stub_provider_slots
      stub_embedder(account, service.name => unit_vector(0))
      index_service(service, unit_vector(0))
      range = { from: (starts_at - 1.hour).iso8601, to: (starts_at + 2.hours).iso8601 }
      inputs = case read_tool
               when 'search_available_slots' then range.merge(resource_ids: [resource.id.to_s], service_id: service.id)
               when 'get_scheduling_resource_availability' then range.merge(resource_id: resource.id, service_id: service.id)
               else range.merge(services: [service.name], doctor: resource.name)
               end
      session.with_lock do |workspace|
        workspace.activate_agent!(assistant)
        workspace.set_permissions!(read: true, write: false)
        initial = business_counts
        observed = call(workspace, read_tool, inputs)
        expect(observed.to_json).to include(starts_at.strftime('%H:%M'))
        expect(workspace.data['catalog_slots']).to include(include('resource_id' => resource.id, 'service_id' => service.id))
        created = call(workspace, 'create_appointment', booking_arguments.merge(starts_at: starts_at.strftime('%Y-%m-%dT%H:%M')))
        expect(created).to include('success' => true, 'simulated' => true)
        expect(created.dig('appointment', 'duration_min')).to eq(20)
        expect(business_counts).to eq(initial)
      end
    end
  end

  it 'requires a fresh observed read after a missing, revoked or replaced provider mapping and permission generation', :aggregate_failures do
    cabinets = [{ 'code' => 'synthetic-cabinet' }]
    resource.update!(custom_attributes: { medelement_cabinets: cabinets })
    stub_provider_slots
    range = { resource_ids: [resource.id.to_s], service_id: service.id, from: (starts_at - 1.hour).iso8601, to: (starts_at + 1.hour).iso8601 }
    session.with_lock do |workspace|
      workspace.activate_agent!(assistant)
      workspace.set_permissions!(read: true, write: false)
      expect(call(workspace, 'create_appointment', booking_arguments)['success']).to be(false)
      resource.update!(custom_attributes: { medelement_cabinets: cabinets, medelement_specialist_code: 'mapping-A' })
      call(workspace, 'search_available_slots', range)
      expect(workspace.data['catalog_slots']).to be_present
      resource.update!(custom_attributes: { medelement_cabinets: cabinets })
      expect(call(workspace, 'create_appointment', booking_arguments)['success']).to be(false)
      resource.update!(custom_attributes: { medelement_cabinets: cabinets, medelement_specialist_code: 'mapping-B' })
      expect(call(workspace, 'create_appointment', booking_arguments)['success']).to be(false)
      call(workspace, 'search_available_slots', range)
      workspace.set_permissions!(read: false, write: false)
      workspace.set_permissions!(read: true, write: false)
      expect(call(workspace, 'create_appointment', booking_arguments)['success']).to be(false)
      call(workspace, 'search_available_slots', range)
      expect(call(workspace, 'create_appointment', booking_arguments)['success']).to be(true)
    end
  end

  it 'invalidates an observed provider offer when the integration route or service changes' do
    provider_hook = create(:integrations_hook, :medelement, account: account)
    resource.update!(custom_attributes: { medelement_specialist_code: 'synthetic-provider' })
    stub_provider_slots
    range = { resource_ids: [resource.id.to_s], service_id: service.id, from: (starts_at - 1.hour).iso8601, to: (starts_at + 1.hour).iso8601 }
    session.with_lock do |workspace|
      workspace.activate_agent!(assistant)
      workspace.set_permissions!(read: true, write: false)
      call(workspace, 'search_available_slots', range)
      provider_hook.update!(settings: provider_hook.settings.merge('organization_id' => 'synthetic-route-B'))
      expect(call(workspace, 'create_appointment', booking_arguments)['success']).to be(false)
      call(workspace, 'search_available_slots', range)
      service.update!(duration_min: 45)
      expect(call(workspace, 'create_appointment', booking_arguments)['success']).to be(false)
      call(workspace, 'search_available_slots', range)
      expect(call(workspace, 'create_appointment', booking_arguments)['success']).to be(true)
      expect(workspace.data['catalog_slots'].to_json).not_to include('company_login', 'password', 'organization_id')
    end
  end

  it 'blocks a mapped catalogue mutation after real reads are revoked and rejects another session handle' do
    foreign = Captain::Playground::SyntheticNamespace.new(SecureRandom.uuid).encode({ id: 101 })[:id]
    session.with_lock do |workspace|
      workspace.activate_agent!(assistant)
      workspace.set_permissions!(read: true, write: false)
      created = call(workspace, 'create_appointment', booking_arguments)
      expect(call(workspace, 'create_appointment', booking_arguments.merge(resource_id: foreign))['success']).to be(false)
      workspace.set_permissions!(read: false, write: false)
      expect(call(workspace, 'update_appointment', appointment_id: created['appointment_id'])['success']).to be(false)
    end
  end
end
