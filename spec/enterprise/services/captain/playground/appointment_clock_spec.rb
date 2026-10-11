require 'rails_helper'

RSpec.describe Captain::Playground::Session, 'appointment clocks through tools and exact action approval' do
  let(:account) { create(:account, reporting_timezone: 'UTC') }
  let(:user) { create(:user, account: account, role: :administrator) }
  let(:tool_ids) { %w[create_appointment update_appointment get_appointment search_appointments] }
  let(:assistant) do
    create(:captain_assistant, account: account, config: {
      'tool_access' => {
        'agent' => { 'enabled' => true, 'tool_ids' => tool_ids },
        'assistant' => { 'enabled' => true, 'tool_ids' => tool_ids }
      }
    })
  end
  let(:session) { described_class.new(account: account, user: user, assistant: assistant) }

  around do |example|
    Time.use_zone('UTC') { travel_to(Time.utc(2026, 10, 11)) { example.run } }
  end

  before do
    account.enable_features!('scheduling')
    allow(Captain::ToolSafety).to receive(:check_arguments!)
    allow(Captain::ToolSafety).to receive(:check_result!)
    expect(Integrations::Medelement::ResourceAvailabilityService).not_to receive(:new)
    expect(Integrations::Medelement::ProviderCommand).not_to receive(:create!)
    expect(Messages::MessageBuilder).not_to receive(:new)
  end

  after { Current.reset }

  def business_counts
    [Scheduling::Appointment, Contact, Message, Crm::Deal, Integrations::Medelement::ProviderCommand].map(&:count)
  end

  def invoke(workspace, id, **arguments)
    definition = Captain::ToolRegistry.definition_for(id)
    tool = if definition.agent_tool_class == Captain::Tools::Agent::AccountToolAdapter
             definition.agent_tool_class.new(assistant, tool_id: id)
           else
             definition.agent_tool_class.new(assistant)
           end
    state = workspace.state.merge(source: 'playground', account_id: account.id, assistant_id: assistant.id)
    context = Captain::Runtime::RunContext.new({ state: state, playground_session: workspace })
    JSON.parse(Captain::Runtime::ToolWrapper.new(tool, context).call(**arguments))
  end

  def configure_synthetic_clock(workspace)
    workspace.scenario.data['resources'].first['timezone'] = 'Asia/Almaty'
    workspace.scenario.validate
  end

  context 'synthetic appointments' do
    before { expect(Scheduling::Appointments::UpsertService).not_to receive(:new) }

    it 'creates local 14:00 in the resource timezone and preserves the instant across the next session turn' do
      session
      baseline = business_counts
      session_id = appointment_id = nil
      session.with_lock do |workspace|
        configure_synthetic_clock(workspace)
        session_id = workspace.id
        scenario = workspace.payload[:scenario]
        result = invoke(workspace, 'create_appointment', resource_id: scenario[:resources].first['id'],
                                                       service_id: scenario[:services].first['id'], starts_at: '2026-10-13T14:00')
        expect(result).to include('success' => true, 'status' => 'created', 'simulated' => true, 'local_time' => '14:00')
        appointment_id = result.fetch('appointment_id')
        expect(appointment_id).to be_negative
        expect(Time.iso8601(result.dig('appointment', 'starts_at'))).to eq(Time.utc(2026, 10, 13, 9))
        expect(Time.iso8601(result.dig('appointment', 'ends_at'))).to eq(Time.utc(2026, 10, 13, 9, 30))
      end

      described_class.new(account: account, user: user, assistant: assistant, session_id: session_id).with_lock do |workspace|
        result = invoke(workspace, 'get_appointment', appointment_id: appointment_id)
        expect(result).to include('success' => true, 'local_time' => '14:00')
        expect(Time.iso8601(result.dig('appointment', 'starts_at'))).to eq(Time.utc(2026, 10, 13, 9))
      end
      expect(business_counts).to eq(baseline)
    end

    it 'updates both local clocks for the identified relative without changing the caller or creating another booking' do
      session
      baseline = business_counts
      session.with_lock do |workspace|
        configure_synthetic_clock(workspace)
        found = invoke(workspace, 'search_appointments', client_identifier: '150101500011').fetch('appointments').first
        result = invoke(workspace, 'update_appointment', appointment_id: found.fetch('appointment_id'),
                                                       appointment_access_token: found.fetch('appointment_access_token'), patient_confirmed: true,
                                                       starts_at: '2026-10-13T14:00', ends_at: '2026-10-13T14:45')
        expect(result).to include('success' => true, 'status' => 'updated', 'simulated' => true, 'local_time' => '14:00')
        expect(Time.iso8601(result.dig('appointment', 'starts_at'))).to eq(Time.utc(2026, 10, 13, 9))
        expect(Time.iso8601(result.dig('appointment', 'ends_at'))).to eq(Time.utc(2026, 10, 13, 9, 45))
        expect(workspace.scenario.data['appointments'].size).to eq(1)
        expect(workspace.scenario.data['appointments'].first).to include('patient_contact_id' => 102, 'duration_min' => 45)
        expect(workspace.scenario.contact['id']).to eq(101)
      end
      expect(business_counts).to eq(baseline)
    end

    it 'keeps an explicit UTC slot instant and detects its collision with the equivalent local 14:00 clock' do
      session
      baseline = business_counts
      session.with_lock do |workspace|
        configure_synthetic_clock(workspace)
        scenario = workspace.payload[:scenario]
        arguments = { resource_id: scenario[:resources].first['id'], service_id: scenario[:services].first['id'] }
        result = invoke(workspace, 'create_appointment', **arguments, starts_at: '2026-10-13T09:00:00Z')
        expect(result).to include('success' => true, 'local_time' => '14:00')
        expect(Time.iso8601(result.dig('appointment', 'starts_at'))).to eq(Time.utc(2026, 10, 13, 9))
        expect(invoke(workspace, 'create_appointment', **arguments, starts_at: '2026-10-13T14:00'))
          .to include('success' => false, 'reason' => 'time_taken')
        expect(workspace.scenario.data['appointments'].size).to eq(2)
      end
      expect(business_counts).to eq(baseline)
    end
  end

  context 'separately approved local database actions' do
    let(:resource_timezone) { 'Asia/Almaty' }
    let(:resource) do
      create(:scheduling_resource, account: account, timezone: resource_timezone).tap do |item|
        create(:scheduling_work_rule, resource: item, weekday: 2, start_minute: 540, end_minute: 1080)
      end
    end
    let(:contact) { create(:contact, account: account) }
    let(:appointment) do
      create(:scheduling_appointment, account: account, resource: resource, service: nil, contact: contact,
                                     patient_contact_id: contact.id, starts_at: Time.utc(2026, 10, 13, 8),
                                     ends_at: Time.utc(2026, 10, 13, 8, 30), source: 'manual')
    end

    shared_examples 'one approved interval' do |input, normalized|
      it 'normalizes the preview and executes exactly that interval only after the digest is confirmed' do
        original = [appointment.starts_at, appointment.ends_at]
        session
        baseline = business_counts
        expect(Scheduling::Appointments::UpsertService).to receive(:new).with(
          account: account, appointment: appointment, params: normalized, actor: user
        ).once.and_call_original

        session.with_lock do |workspace|
          workspace.set_permissions!(read: true, write: true)
          approval = Captain::Playground::ActionApproval.new(workspace)
          preview = approval.preview('update_appointment', input.merge(appointment_id: appointment.id))
          expect(preview.fetch('arguments')).to eq(normalized.merge(appointment_id: appointment.id).deep_stringify_keys)
          expect(preview['status']).to eq('pending')
          expect([appointment.reload.starts_at, appointment.ends_at]).to eq(original)
          expect(business_counts).to eq(baseline)

          result = approval.confirm(id: preview.fetch('id'), digest: preview.fetch('digest'))
          expect(result).to include(success: true, delivered: false)
          expect(preview['status']).to eq('completed')
          receipt = JSON.parse(result.fetch(:result))
          expect(receipt).to include('action' => 'update_appointment', 'appointment_id' => appointment.id,
                                     'resource_id' => resource.id, 'status' => 'scheduled', 'provider_confirmation_required' => false)
          expect(Time.iso8601(receipt.fetch('starts_at'))).to eq(Time.utc(2026, 10, 13, 9))
          expect(Time.iso8601(receipt.fetch('ends_at'))).to eq(Time.utc(2026, 10, 13, 9, 30))
          expect(appointment.reload.starts_at).to eq(Time.utc(2026, 10, 13, 9))
          expect(appointment.ends_at).to eq(Time.utc(2026, 10, 13, 9, 30))
          expect(appointment.patient_contact_id).to eq(contact.id)
          expect { approval.confirm(id: preview.fetch('id'), digest: preview.fetch('digest')) }.to raise_error(ArgumentError, /revoked/)
        end
        expect(business_counts).to eq(baseline)
      end
    end

    context 'a local clock with inferred duration' do
      include_examples 'one approved interval', { starts_at: '2026-10-13T14:00' },
                       { starts_at: '2026-10-13T14:00:00+05:00', ends_at: '2026-10-13T14:30:00+05:00' }
    end

    context 'an explicit offset with an exact end' do
      include_examples 'one approved interval', { starts_at: '2026-10-13T10:00:00+01:00', ends_at: '2026-10-13T10:30:00+01:00' },
                       { starts_at: '2026-10-13T10:00:00+01:00', ends_at: '2026-10-13T10:30:00+01:00' }
    end

    context 'a resource with daylight saving transitions' do
      let(:resource_timezone) { 'Europe/Berlin' }

      ['2026-10-25T02:30', '2027-03-28T02:30'].each do |clock|
        it "rejects the ambiguous or missing local clock #{clock} before issuing an approval or changing a booking" do
          original = appointment.attributes
          expect(Scheduling::Appointments::UpsertService).not_to receive(:new)
          session.with_lock do |workspace|
            workspace.set_permissions!(read: true, write: true)
            expect do
              Captain::Playground::ActionApproval.new(workspace).preview('update_appointment', appointment_id: appointment.id, starts_at: clock)
            end.to raise_error(Scheduling::Error) do |error|
              expect(error.code).to eq('INVALID_DATE')
              expect(error.details).to include(field: 'starts_at', mutation_executed: false)
            end
            expect(workspace.payload[:action_previews]).to be_empty
          end
          expect(appointment.reload.attributes).to eq(original)
        end
      end
    end
  end
end
