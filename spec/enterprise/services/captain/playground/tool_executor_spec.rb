require 'rails_helper'

RSpec.describe Captain::Playground::ToolExecutor do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account, role: :administrator) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:session) { Captain::Playground::Session.new(account: account, user: user, assistant: assistant) }

  before do
    account.enable_features!('scheduling', 'crm_deals', 'crm_tasks')
    allow(Captain::ToolSafety).to receive(:check_arguments!)
    allow(Captain::ToolSafety).to receive(:check_result!)
  end

  def invoke(trial, tool, **arguments)
    state = trial.state.merge(source: 'playground', account_id: account.id, assistant_id: assistant.id)
    context = Captain::Runtime::ToolContext.new(run_context: Captain::Runtime::RunContext.new({ state: state, playground_session: trial }))
    described_class.new(trial).execute(tool, arguments, context: context).deep_symbolize_keys
  end

  it 'persists contact and deal changes so subsequent turns and reads see the same values' do
    id = nil
    session.with_lock do |trial|
      id = trial.id
      expect(invoke(trial, 'update_contact', name: 'Caller edited').dig(:contact, :name)).to eq('Caller edited')
      expect(invoke(trial, 'update_deal', deal_id: 501, title: 'Changed deal', amount: '200.00')[:amount]).to eq(200)
    end
    Captain::Playground::Session.new(account: account, user: user, assistant: assistant, session_id: id).with_lock do |trial|
      expect(invoke(trial, 'get_contact', contact_id: 101)[:name]).to eq('Caller edited')
      expect(invoke(trial, 'get_deal', deal_id: 501).dig(:deal, :title)).to eq('Changed deal')
      expect(invoke(trial, 'update_deal', deal_id: 501, amount: '200.50')[:success]).to be(false)
      expect(invoke(trial, 'get_deal', deal_id: 501).dig(:deal, :amount)).to eq(200)
    end
  end

  it 'books into synthetic availability and returns a conflict for a second overlapping booking' do
    expect(Scheduling::Appointments::UpsertService).not_to receive(:new)
    expect(Captain::Tools::Operations::AppointmentOperations).not_to receive(:new)
    expect(Integrations::Medelement::ProviderCommand).not_to receive(:create!)
    expect(Messages::MessageBuilder).not_to receive(:new)
    before_counts = [Scheduling::Appointment.count, Contact.count, Message.count]
    session.with_lock do |trial|
      start = (Time.iso8601(trial.scenario.data['appointments'].first['starts_at']) + 1.hour).iso8601
      result = invoke(trial, 'create_appointment', resource_id: 701, service_id: 801, starts_at: start)
      expect(result).to include(success: true, status: 'created', simulated: true)
      expect(invoke(trial, 'get_appointment', appointment_id: result[:appointment_id])).to include(success: true)
      expect(invoke(trial, 'create_appointment', resource_id: 701, service_id: 801, starts_at: start)).to include(success: false, reason: 'time_taken')
      slots = invoke(trial, 'search_available_slots', resource_ids: [701], service_id: 801, from: start,
                                                    to: (Time.iso8601(start) + 2.hours).iso8601)
      expect(slots[:slots].map { |slot| slot[:starts_at] }).not_to include(start)
    end
    expect([Scheduling::Appointment.count, Contact.count, Message.count]).to eq(before_counts)
  end

  it 'finds the son by exact IIN, requires confirmation, changes only his appointment, and preserves the mother caller' do
    session.with_lock do |trial|
      result = invoke(trial, 'search_appointments', client_identifier: '150101500011')
      found = result[:appointments].first
      expect(found).to include(appointment_id: 601, patient_name: 'Тимур Садыков')
      expect(found[:appointment_access_token]).to start_with("trial_#{trial.id}_")
      start = (Time.iso8601(trial.scenario.data['appointments'].first['starts_at']) + 1.hour).iso8601
      denied = invoke(trial, 'update_appointment', appointment_id: 601, starts_at: start, appointment_access_token: found[:appointment_access_token])
      expect(denied[:success]).to be(false)
      changed = invoke(trial, 'update_appointment', appointment_id: 601, starts_at: start,
                                                  appointment_access_token: found[:appointment_access_token], patient_confirmed: true)
      expect(changed).to include(success: true, status: 'updated')
      expect(trial.scenario.contact['id']).to eq(101)
      expect(trial.scenario.data['appointments'].first).to include('contact_id' => 102, 'patient_contact_id' => 102, 'starts_at' => start)
      expect(invoke(trial, 'get_appointment', appointment_id: 601, appointment_access_token: found[:appointment_access_token])[:success]).to be(false)
      fresh = invoke(trial, 'search_appointments', client_identifier: '150101500011')[:appointments].first
      expect(invoke(trial, 'cancel_appointment', appointment_id: 601, appointment_access_token: fresh[:appointment_access_token], patient_confirmed: true))
        .to include(success: true, status: 'cancelled')
      expect(invoke(trial, 'list_my_appointments')[:appointments]).to eq([])
    end
  end

  it 'fails closed for network, custom, and unknown tools and for guessed cross-patient IDs' do
    session.with_lock do |trial|
      %w[web_search custom_http_tool mcp__remote__write].each do |name|
        result = invoke(trial, name)
        expect(Captain::ToolResult.error?(Captain::ToolResult.normalize(result))).to be(true)
      end
      expect(invoke(trial, 'get_contact', contact_id: 102)[:success]).to be(false)
      expect(invoke(trial, 'get_appointment', appointment_id: 601)[:success]).to be(false)
      expect(invoke(trial, 'create_appointment', resource_id: 999, starts_at: 2.days.from_now.iso8601)[:success]).to be(false)
    end
  end

  it 'uses the runtime wrapper boundary before any actual tool delegate or tool audit' do
    session.with_lock do |trial|
      tool = Captain::Tools::UpdateContactTool.new(assistant)
      expect(tool).not_to receive(:execute)
      expect(Captain::ToolExecutionAuditService).not_to receive(:record)
      state = trial.state.merge(source: 'playground', account_id: account.id, assistant_id: assistant.id)
      context = Captain::Runtime::RunContext.new({ state: state, playground_session: trial,
                                                 captain_v2_bound_tool_gate: true, captain_v2_bound_tool_ids: ['update_contact'] })
      result = JSON.parse(Captain::Runtime::ToolWrapper.new(tool, context).call(name: 'Isolated caller'))
      expect(result.to_json).to include('Isolated caller')
      expect(trial.scenario.contact['name']).to eq('Isolated caller')
    end
  end

  it 'keeps normal bound-tool checks and denies a Playground context without a server session' do
    tool = Captain::Tools::UpdateContactTool.new(assistant)
    expect(tool).not_to receive(:execute)
    session.with_lock do |trial|
      state = trial.state.merge(source: 'playground', account_id: account.id, assistant_id: assistant.id)
      unbound = Captain::Runtime::RunContext.new({ state: state, playground_session: trial,
                                                 captain_v2_bound_tool_gate: true, captain_v2_bound_tool_ids: [] })
      expect(Captain::Runtime::ToolWrapper.new(tool, unbound).call(name: 'Forbidden')).to include('Tool is not available')
      missing = Captain::Runtime::RunContext.new({ state: state })
      expect(Captain::Runtime::ToolWrapper.new(tool, missing).call(name: 'Forbidden')).to include('server-owned Playground session')
    end
  end
end
