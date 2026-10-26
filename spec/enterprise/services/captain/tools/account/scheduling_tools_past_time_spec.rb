require 'rails_helper'

# In a patient conversation the scheduling tools never read or offer a time before now (the clinic's clock), and a booking or a
# move to a start that has passed is refused with a business answer that names now, on every path that books: the agent's own
# tools, the approval card of a reply suggestion and Copilot. Staff keep the ranges they ask for. All data is synthetic.
RSpec.describe 'Scheduling tools and times that have passed' do # rubocop:disable RSpec/DescribeClass
  include ActiveSupport::Testing::TimeHelpers

  # Tuesday, 21 April 2026, 12:00 in Almaty; the specialist receives Monday to Friday 09:00-18:00 every 30 minutes.
  let(:now) { Time.zone.parse('2026-04-21 12:00:00 +0500') }
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:inbox) { create(:inbox, account: account, timezone: 'Asia/Almaty') }
  let(:contact) { create(:contact, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, contact: contact) }
  let(:resource) { create(:scheduling_resource, account: account, name: 'Aigerim', timezone: 'Asia/Almaty', slot_duration_min: 30) }
  let(:consultation) { create(:scheduling_service, account: account, name: 'Consultation', duration_min: 30, base_price: 20_000) }
  let(:now_label) { 'Tuesday, 21 April 2026 (2026-04-21), 12:00' }

  around { |example| travel_to(now) { example.run } }

  before do
    account.enable_features!('scheduling')
    (1..5).each do |weekday|
      create(:scheduling_work_rule, resource: resource, account: account, weekday: weekday, start_minute: 9 * 60, end_minute: 18 * 60)
    end
    create(:scheduling_service_price, account: account, service: consultation, resource: resource, active: true, price: 20_000)
  end

  def agent(tool_class)
    tool_class.new(assistant, user: assistant, conversation: conversation).tap do |tool|
      tool.patient_scope = Captain::Tools::Agent::PatientScope.new(assistant: assistant, conversation: conversation)
    end
  end

  def staff(tool_class)
    tool_class.new(assistant, user: user)
  end

  describe 'search_available_slots' do
    let(:tool_class) { Captain::Tools::Account::SearchAvailableSlotsService }

    def search(**range)
      JSON.parse(agent(tool_class).execute(resource_ids: [resource.id], service_id: consultation.id, **range))
    end

    it 'answers a day that has passed without its free times, with now and the nearest free days from now' do
      answer = search(from: '2026-04-20', to: '2026-04-21')

      expect(answer).to include('total' => 0, 'days' => [], 'requested_range_status' => 'range_passed')
      expect(answer['requested_range_note']).to include(now_label, 'next_available')
      expect(answer['next_available'].first).to include('resource_id' => resource.id, 'date' => '2026-04-21')
      expect(answer['next_available'].first['times']).to all(be >= '12:00')
      expect(answer['next_available'].pluck('date')).to all(be >= '2026-04-21')
    end

    it 'answers one exact time earlier today as passed' do
      answer = search(from: '2026-04-21T10:00', to: '2026-04-21T10:00')

      expect(answer).to include('days' => [], 'requested_range_status' => 'range_passed')
      expect(answer['next_available'].first['date']).to eq('2026-04-21')
    end

    it 'starts a range that began earlier today at now' do
      answer = search(from: '2026-04-21', to: '2026-04-22')

      expect(answer['days'].pluck('date')).to eq(['2026-04-21'])
      expect(answer['days'].first['times']).to all(be >= '12:00')
      expect(answer).not_to have_key('requested_range_status')
    end

    it 'keeps the range staff ask for' do
      payload = JSON.parse(staff(tool_class).execute(from: '2026-04-20T09:00:00+05:00', to: '2026-04-20T10:00:00+05:00',
                                                     resource_ids: [resource.id], service_id: consultation.id))

      expect(payload['slots'].pluck('starts_at')).to include('2026-04-20T09:00:00+05:00')
    end
  end

  describe 'get_scheduling_resource_availability' do
    let(:tool_class) { Captain::Tools::Account::GetSchedulingResourceAvailabilityService }

    it 'answers a range that has passed without free windows, with now' do
      payload = JSON.parse(agent(tool_class).execute(resource_id: resource.id, from: '2026-04-20T09:00', to: '2026-04-20T18:00'))

      expect(payload).to include('slots' => [], 'total_slots' => 0, 'requested_range_status' => 'range_passed')
      expect(payload['requested_range_note']).to include(now_label, 'search_available_slots')
    end

    it 'gives only the free windows from now of a range that began earlier' do
      payload = JSON.parse(agent(tool_class).execute(resource_id: resource.id, from: '2026-04-21T09:00', to: '2026-04-21T18:00'))

      expect(payload['slots']).not_to be_empty
      expect(payload['slots'].pluck('starts_at')).to all(be >= '2026-04-21T12:00:00+05:00')
    end

    it 'keeps the range staff ask for' do
      payload = JSON.parse(staff(tool_class).execute(resource_id: resource.id, from: '2026-04-20T09:00:00+05:00',
                                                     to: '2026-04-20T18:00:00+05:00'))

      expect(payload['slots'].pluck('starts_at')).to include('2026-04-20T09:00:00+05:00')
    end
  end

  describe 'get_scheduling_resource_schedule' do
    let(:tool_class) { Captain::Tools::Account::GetSchedulingResourceScheduleService }

    it 'answers days that have passed without their working hours, with now' do
      payload = JSON.parse(agent(tool_class).execute(resource_id: resource.id, from: '2026-04-20T00:00', to: '2026-04-21T00:00'))

      expect(payload).to include('days' => [], 'requested_range_status' => 'range_passed')
      expect(payload['requested_range_note']).to include(now_label)
    end

    it 'starts today at now' do
      payload = JSON.parse(agent(tool_class).execute(resource_id: resource.id, from: '2026-04-21T00:00', to: '2026-04-22T00:00'))

      expect(payload['days'].pluck('date')).to eq(['2026-04-21'])
      expect(payload['days'].first['windows']).to eq([{ 'start_at' => '2026-04-21T12:00:00+05:00', 'end_at' => '2026-04-21T18:00:00+05:00' }])
    end

    it 'keeps the range staff ask for' do
      payload = JSON.parse(staff(tool_class).execute(resource_id: resource.id, from: '2026-04-20T00:00:00+05:00',
                                                     to: '2026-04-21T00:00:00+05:00'))

      expect(payload['days'].pluck('date')).to eq(['2026-04-20'])
      expect(payload['days'].first['windows'].first['start_at']).to eq('2026-04-20T09:00:00+05:00')
    end
  end

  describe 'a booking or a move to a start that has passed' do
    let(:tool_context) { Struct.new(:state).new({ conversation: { id: conversation.id }, contact: { id: contact.id } }) }

    def expect_start_in_past(result)
      normalized = Captain::ToolResult.normalize(result)
      expect(normalized).to include(success: false)
      expect(normalized[:error]).to include('That start has passed (now is Tuesday 2026-04-21 12:00)', 'search_available_slots')
      expect(normalized[:data].to_h.with_indifferent_access).to include('code' => 'START_IN_PAST', 'error_class' => 'business',
                                                                        'next_tool' => 'search_available_slots')
      expect(normalized[:audit].to_h.with_indifferent_access).to include('mutation_executed' => false, 'failure_stage' => 'tool_arguments')
      expect(Captain::Runtime::ToolFailure.classify(result)).to eq('business')
    end

    it 'is refused by create_appointment of the agent, earlier today and on an earlier day, and nothing is created' do
      tool = Captain::Tools::CreateAppointmentTool.new(assistant)

      expect do
        %w[2026-04-21T10:00 2026-04-20T15:00].each do |starts_at|
          expect_start_in_past(tool.perform(tool_context, resource_id: resource.id, service_id: consultation.id, starts_at: starts_at))
        end
      end.not_to(change { account.scheduling_appointments.count })
    end

    it 'lets a start after now through the check' do
      result = Captain::Tools::CreateAppointmentTool.new(assistant)
                                                    .perform(tool_context, resource_id: resource.id, service_id: consultation.id,
                                                                           starts_at: '2026-04-22T10:00')

      expect(result.to_s).not_to include('START_IN_PAST')
    end

    it 'is refused by update_appointment of the agent, and the appointment keeps its time' do
      starts_at = Time.zone.parse('2026-04-22 10:00:00 +0500')
      appointment = create(:scheduling_appointment, account: account, resource: resource, service: consultation, contact: contact,
                                                    conversation_id: conversation.id, starts_at: starts_at,
                                                    ends_at: starts_at + 30.minutes, duration_min: 30)
      context = Struct.new(:state).new({ conversation: { id: conversation.id }, appointment: { id: appointment.id }, contact: { id: contact.id } })

      expect_start_in_past(Captain::Tools::UpdateAppointmentTool.new(assistant)
                                                               .perform(context, appointment_id: appointment.id, starts_at: '2026-04-21T09:30'))
      expect(appointment.reload.starts_at).to eq(starts_at)
    end

    it 'prepares no approval card in a reply suggestion' do
      assistant.update!(config: { 'tool_access' => { 'agent' => { 'enabled' => true, 'tool_ids' => %w[create_appointment] } } })
      run_context = Captain::Runtime::RunContext.new(
        { state: { account_id: account.id, assistant_id: assistant.id, entry_assistant_id: assistant.id, source: 'reply_suggestion',
                   conversation: { id: conversation.id, display_id: conversation.display_id }, contact: { id: contact.id } },
          current_agent: assistant.agent_name, acting_assistant_id: assistant.id }
      )

      result = Captain::ReplySuggestion::ActionApprovalService.intercept(
        tool: Captain::Tools::CreateAppointmentTool.new(assistant), tool_context: Captain::Runtime::ToolContext.new(run_context: run_context),
        arguments: { resource_id: resource.id, service_id: consultation.id, starts_at: '2026-04-21T11:00' }
      )

      expect_start_in_past(result)
      expect(Captain::ReplySuggestion::ActionApprovalService.pending_for(account_id: account.id, conversation_id: conversation.id)).to be_empty
    end

    it 'is refused for Copilot once the operator confirmed it, with the reason in the message' do
      admin = create(:user, :administrator, account: account)
      thread = create(:captain_copilot_thread, account: account, user: admin, assistant: assistant)
      copilot = Captain::Tools::Account::CreateAppointmentService.new(assistant, user: admin, conversation: conversation, copilot_thread: thread)
      arguments = { resource_id: resource.id, service_id: consultation.id, starts_at: '2026-04-21T11:00:00+05:00' }

      first = JSON.parse(copilot.execute(**arguments))
      token = thread.copilot_messages.assistant_thinking.last.message.dig('confirmation_gate', 'confirmation_token')
      create(:captain_copilot_message, account: account, copilot_thread: thread, message_type: 'user',
                                       message: { 'content' => "Подтверждаю #{token}" })
      result = copilot.execute(**arguments)

      expect(first.dig('data', 'confirmation_required')).to be(true)
      expect(result).to include('has passed (now is Tuesday 2026-04-21 12:00)', 'START_IN_PAST')
      expect(account.scheduling_appointments.count).to eq(0)
    end
  end
end
