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
    result = described_class.new(trial).execute(tool, arguments, context: context)
    result = JSON.parse(result) if result.is_a?(String)
    trial.namespace.decode(result).deep_symbolize_keys
  end

  it 'persists contact and deal changes so subsequent turns and reads see the same values' do
    id = nil
    session.with_lock do |trial|
      id = trial.id
      expect(invoke(trial, 'update_contact', name: 'Caller edited').dig(:contact, :name)).to eq('Caller edited')
      expect(invoke(trial, 'update_deal', deal_id: 501, title: 'Changed deal', amount: '200.00')[:amount]).to eq(200)
    end
    Captain::Playground::Session.new(account: account, user: user, assistant: assistant, session_id: id).with_lock do |trial|
      expect(invoke(trial, 'get_contact', contact_id: 101).dig(:contact, :name)).to eq('Caller edited')
      expect(invoke(trial, 'get_deal', deal_id: 501).dig(:deal, :title)).to eq('Changed deal')
      expect(invoke(trial, 'update_deal', deal_id: 501, amount: '200.50')[:success]).to be(false)
      expect(invoke(trial, 'get_deal', deal_id: 501).dig(:deal, :amount)).to eq(200)
    end
  end

  it 'books into synthetic availability and returns a conflict for a second overlapping booking' do
    expect(Scheduling::Appointments::UpsertService).not_to receive(:new)
    expect(Integrations::Medelement::ProviderCommand).not_to receive(:create!)
    expect(Messages::MessageBuilder).not_to receive(:new)
    before_counts = [Scheduling::Appointment.count, Contact.count, Message.count]
    session.with_lock do |trial|
      start = (Time.iso8601(trial.scenario.data['appointments'].first['starts_at']) + 1.hour).iso8601
      result = invoke(trial, 'create_appointment', resource_id: 701, service_id: 801, starts_at: start)
      expect(result).to include(success: true, status: 'created', simulated: true)
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
      start = (Time.iso8601(trial.scenario.data['appointments'].first['starts_at']) + 1.hour).iso8601
      denied = invoke(trial, 'update_appointment', appointment_id: 601, starts_at: start, appointment_access_token: found[:appointment_access_token])
      expect(denied[:success]).to be(false)
      changed = invoke(trial, 'update_appointment', appointment_id: 601, starts_at: start,
                                                  appointment_access_token: found[:appointment_access_token], patient_confirmed: true)
      expect(changed).to include(success: true, status: 'updated')
      expect(trial.scenario.contact['id']).to eq(101)
      expect(trial.scenario.data['appointments'].first).to include('contact_id' => 102, 'patient_contact_id' => 102, 'starts_at' => start)
      fresh = invoke(trial, 'search_appointments', client_identifier: '150101500011')[:appointments].first
      expect(invoke(trial, 'cancel_appointment', appointment_id: 601, appointment_access_token: fresh[:appointment_access_token], patient_confirmed: true))
        .to include(success: true, status: 'cancelled')
      expect(invoke(trial, 'list_my_appointments')[:appointments]).to eq([])
    end
  end

  it 'keeps a child appointment private despite sharing the caller conversation and invalidates grants after a change' do
    session.with_lock do |trial|
      appointment = trial.scenario.data['appointments'].first
      appointment.merge!('contact_id' => 101, 'conversation_id' => 201)
      expect(invoke(trial, 'search_appointments')[:appointments]).to eq([])
      expect(invoke(trial, 'get_appointment', appointment_id: 601)[:success]).to be(false)
      expect(trial.state.dig(:appointment, :id)).to be_nil
      token = invoke(trial, 'search_appointments', client_identifier: '150101500011')[:appointments].first[:appointment_access_token]
      expect(token).to start_with("trial_#{trial.id}_")
      start = (Time.iso8601(appointment['starts_at']) + 1.hour).iso8601
      invoke(trial, 'update_appointment', appointment_id: 601, starts_at: start, appointment_access_token: token, patient_confirmed: true)

      expect(invoke(trial, 'get_appointment', appointment_id: 601, appointment_access_token: token)[:success]).to be(false)
    end
  end

  it 'requires matching recorded names and birth date to reuse a synthetic patient with an exact IIN' do
    session.with_lock do |trial|
      start = (Time.iso8601(trial.scenario.data['appointments'].first['starts_at']) + 1.hour).iso8601
      arguments = { resource_id: 701, service_id: 801, starts_at: start }
      patient = { first_name: 'Тимур', last_name: 'Садыков', iin: '150101500011', birth_date: '2015-01-01' }
      original = trial.scenario.data.deep_dup
      wrong_name = invoke(trial, 'create_appointment', **arguments, patient: patient.merge(last_name: 'Другой'))
      expect(wrong_name).to include(success: false, reason: 'validation_error')
      wrong_birth_date = invoke(trial, 'create_appointment', **arguments, patient: patient.merge(birth_date: '2015-02-01'))
      expect(wrong_birth_date).to include(success: false, reason: 'validation_error')
      expect(trial.scenario.data).to eq(original)
      result = invoke(trial, 'create_appointment', **arguments, patient: patient)
      expect(result[:success]).to be(true)
      created = trial.scenario.data['appointments'].find { |record| record['id'] == result[:appointment_id] }
      expect(created).to include('patient_contact_id' => 102, 'contact_id' => 101, 'client_name' => 'Тимур Садыков')
    end
  end

  it 'creates a distinct clinical card without IIN and reuses only its identical creation request' do
    expect(Scheduling::PatientContactCreationService).not_to receive(:new)
    session.with_lock do |trial|
      start = (Time.iso8601(trial.scenario.data['appointments'].first['starts_at']) + 1.hour).iso8601
      patient = { first_name: 'Тимур', last_name: 'Садыков', birth_date: '2015-01-01' }
      result = invoke(trial, 'create_appointment', resource_id: 701, service_id: 801, starts_at: start, patient: patient)
      expect(result[:success]).to be(true)
      first = trial.scenario.data['appointments'].find { |record| record['id'] == result[:appointment_id] }
      expect(first['patient_contact_id']).not_to eq(102)
      card = trial.scenario.data['contacts'].find { |record| record['id'] == first['patient_contact_id'] }
      expect(card).to include('phone_number' => nil, 'name' => 'Тимур Садыков')
      expect(card['custom_attributes']).to include('secondary_phones' => ['+77010000001'], 'medelement_shared_phone_owner_contact_id' => 101)
      again = invoke(trial, 'create_appointment', resource_id: 701, service_id: 801,
                                                 starts_at: (Time.iso8601(start) + 1.hour).iso8601, patient: patient)
      second = trial.scenario.data['appointments'].find { |record| record['id'] == again[:appointment_id] }
      expect(second).to include('patient_contact_id' => card['id'], 'contact_id' => 101, 'client_phone' => '+77010000001')
      expect(trial.scenario.contact['id']).to eq(101)
    end
  end

  it 'persists native task statuses and fields while rejecting unknown statuses and staff assignment' do
    expect(Crm::Tasks::UpsertService).not_to receive(:new)
    id = nil
    task_id = nil
    session.with_lock do |trial|
      id = trial.id
      task = invoke(trial, 'create_task', title: 'Позвонить маме', activity_type: 'call', priority: 'high')
      task_id = task[:task_id]
      expect(task.dig(:task, :status_code)).to eq('todo')
      trial.scenario.data['selection']['task_id'] = task_id
      expect(invoke(trial, 'change_task_status', status_code: 'done').dig(:task, :completed_at)).to be_present
      expect(invoke(trial, 'update_task', task_id: task_id, outcome: 'invented')[:success]).to be(false)
    end
    Captain::Playground::Session.new(account: account, user: user, assistant: assistant, session_id: id).with_lock do |trial|
      expect(invoke(trial, 'get_task', task_id: task_id).dig(:task, :status_code)).to eq('done')
      expect(invoke(trial, 'search_tasks', assignee_id: 999)[:success]).to be(false)
      expect(invoke(trial, 'change_task_status', status_code: 'invented')[:success]).to be(false)
    end
  end

  it 'moves a deal by the configured stage order and rejects moving before the first stage' do
    session.with_lock do |trial|
      expect(invoke(trial, 'transition_deal_stage', deal_id: 501, stage_action: 'previous')[:success]).to be(false)
      moved = invoke(trial, 'transition_deal_stage', deal_id: 501, stage_action: 'next')
      expect(moved.dig(:previous_stage, :id)).to eq(911)
      expect(moved.dig(:current_stage, :id)).to eq(912)
      expect(invoke(trial, 'get_deal', deal_id: 501).dig(:deal, :stage_id)).to eq(912)
      expect(invoke(trial, 'transition_deal_stage', deal_id: 501, stage_id: 911, stage_action: 'next')[:success]).to be(false)
    end
  end

  it 'simulates idempotent confirmation delivery and resolution without creating a native request or message' do
    expect(Confirmations::CreateService).not_to receive(:new)
    expect(Messages::MessageBuilder).not_to receive(:new)
    session.with_lock do |trial|
      arguments = { title: 'Подтвердите запись', body: 'Подтвердите время', idempotency_key: 'booking-confirmation',
                    subject_type: 'Crm::Deal', subject_id: 501 }
      first = invoke(trial, 'request_confirmation', **arguments)
      second = invoke(trial, 'request_confirmation', **arguments)
      expect(invoke(trial, 'get_confirmation_request').dig(:confirmation_request, :id)).to eq(first.dig(:confirmation_request, :id))
      expect(trial.scenario.data['messages'].size).to eq(1)
      expect(second[:delivery]).to include(status: 'simulated', delivery_confirmed: false)
      id = first.dig(:confirmation_request, :id)
      expect(invoke(trial, 'resolve_confirmation', confirmation_request_id: id, decision: 'confirm', source: 'ai')
               .dig(:confirmation_request, :status)).to eq('confirmed')
      expect(invoke(trial, 'resolve_confirmation', confirmation_request_id: id, decision: 'decline', source: 'ai')[:success]).to be(false)
    end
  end

  it 'preserves profile restrictions in Trial despite an administrator launching the session' do
    session.with_lock do |trial|
      expect(invoke(trial, 'get_conversation', conversation_id: 201)[:success]).to be(false)
      expect(invoke(trial, 'complete_task', task_id: 1)[:success]).to be(false)
      expect(invoke(trial, 'search_conversations', status: 'open').dig(:conversations, 0, :contact_id)).to eq(101)
      expect(invoke(trial, 'search_conversations', contact_id: 102)[:success]).to be(false)
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
      expect(Captain::Runtime::ToolWrapper.new(tool, missing).call(name: 'Forbidden')).to include('Playground')
    end
  end
end
