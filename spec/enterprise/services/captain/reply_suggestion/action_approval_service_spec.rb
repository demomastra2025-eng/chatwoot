# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::ReplySuggestion::ActionApprovalService do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account, role: :administrator, name: 'Оператор Анна') }
  let(:inbox) { create(:inbox, account: account) }
  let(:contact) { create(:contact, account: account, name: 'Иван Петров', phone_number: '+77011234567') }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, contact: contact) }
  let(:assistant) do
    create(
      :captain_assistant,
      account: account,
      name: 'Координатор',
      active: true,
      config: {
        'tool_access' => {
          'agent' => {
            'enabled' => true,
            'tool_ids' => %w[create_appointment update_appointment cancel_appointment create_task]
          }
        }
      }
    )
  end

  let(:run_context) do
    Captain::Runtime::RunContext.new(
      {
        state: {
          account_id: account.id,
          assistant_id: assistant.id,
          entry_assistant_id: assistant.id,
          source: 'reply_suggestion',
          conversation: {
            id: conversation.id,
            display_id: conversation.display_id
          },
          contact: {
            id: contact.id,
            name: contact.name,
            phone_number: contact.phone_number
          }
        },
        current_agent: assistant.agent_name,
        acting_assistant_id: assistant.id
      }
    )
  end
  let(:tool_context) { Captain::Runtime::ToolContext.new(run_context: run_context) }

  let!(:resource) do
    account.scheduling_resources.create!(
      name: 'Д-р Смит',
      active: true
    )
  end

  let!(:service_item) do
    account.scheduling_services.create!(
      name: 'Консультация терапевта',
      duration_min: 30,
      base_price: 10_000,
      active: true
    )
  end

  let(:starts_at) { 2.days.from_now.change(hour: 10, min: 0, sec: 0).iso8601 }
  let(:ends_at) { 2.days.from_now.change(hour: 10, min: 30, sec: 0).iso8601 }

  # A corrected time of the same day.
  def later_starts_at = 2.days.from_now.change(hour: 11, min: 30, sec: 0).iso8601
  def later_ends_at = 2.days.from_now.change(hour: 12, min: 0, sec: 0).iso8601

  # Another specialist for a second visit of the same patient.
  def create_endocrinologist = account.scheduling_resources.create!(name: 'Д-р Ли', active: true)

  # The booking cards that one suggestion request prepares in a run of its own, one per list of arguments.
  def suggest_bookings(request_id, context, *arguments_list)
    tool = Captain::Tools::CreateAppointmentTool.new(assistant)
    Captain::ReplySuggestion::RunControl.with(request_id: request_id, deadline: Process.clock_gettime(Process::CLOCK_MONOTONIC) + 60) do
      arguments_list.map { |arguments| JSON.parse(described_class.intercept(tool: tool, tool_context: context, arguments: arguments)) }
    end
  end

  # The tool context of the next suggestion of the conversation: the cards of the earlier one are not its own.
  def next_suggestion_context
    Captain::Runtime::ToolContext.new(run_context: Captain::Runtime::RunContext.new(
      run_context.context.deep_dup.merge(captain_suggestion_pending_actions: [], captain_suggestion_superseded_actions: [])
    ))
  end

  def keep_suggestion!(request_id)
    described_class.keep_for_request!(account_id: account.id, conversation_id: conversation.id, request_id: request_id)
  end

  def pending_ids(request_id)
    described_class.pending_for(account_id: account.id, conversation_id: conversation.id, request_id: request_id).pluck('action_id')
  end

  before do
    if defined?(Scheduling::ServicePrice)
      Scheduling::ServicePrice.find_or_create_by!(
        account: account,
        resource_id: resource.id,
        service_id: service_item.id
      ) do |sp|
        sp.price = 10_000 if sp.respond_to?(:price=)
        sp.active = true if sp.respond_to?(:active=)
      end
    end
    allow(account).to receive(:feature_enabled?).and_call_original
    allow(account).to receive(:feature_enabled?).with('scheduling').and_return(true)
    allow(account).to receive(:feature_enabled?).with('crm_scheduling').and_return(true)
    allow(account).to receive(:feature_enabled?).with('crm').and_return(true)
  end

  describe '.intercept' do
    let(:create_tool) { Captain::Tools::CreateAppointmentTool.new(assistant) }

    it 'intercepts create_appointment without creating a record and stores a pending proposal' do
      args = {
        resource_id: resource.id,
        service_id: service_item.id,
        starts_at: starts_at,
        ends_at: ends_at
      }

      raw_result = nil
      expect do
        raw_result = described_class.intercept(
          tool: create_tool,
          tool_context: tool_context,
          arguments: args
        )
      end.not_to(change { account.scheduling_appointments.count })

      result = JSON.parse(raw_result)
      expect(result['status']).to eq('pending_operator_approval')
      expect(result['operator_approval_required']).to be(true)
      expect(result['action_id']).to be_present
      expect(result['title']).to eq('Записать на приём')
      expect(result['details']).to include(
        hash_including('label' => 'Специалист', 'value' => 'Д-р Смит'),
        hash_including('label' => 'Услуга', 'value' => 'Консультация терапевта'),
        hash_including('label' => 'Пациент', 'value' => 'Иван Петров, +77011234567')
      )

      pending = described_class.pending_for(account_id: account.id, conversation_id: conversation.id)
      expect(pending.size).to eq(1)
      expect(pending.first['action_id']).to eq(result['action_id'])
      expect(pending.first.dig('agent', 'name')).to eq('Координатор')
      expect(run_context.context[described_class::CONTEXT_KEY].size).to eq(1)
    end

    # A contact update read as a booking once made a draft say "the booking waits for the administrator" with no booking card.
    it 'tells the agent exactly what waits for the operator and which cards the run prepared' do
      account.enable_features!('crm', 'crm_tasks')
      task = JSON.parse(described_class.intercept(tool: Captain::Tools::CreateTaskTool.new(assistant), tool_context: tool_context,
                                                  arguments: { title: 'Перезвонить пациенту' }))
      booking = JSON.parse(described_class.intercept(tool: create_tool, tool_context: tool_context,
                                                     arguments: { resource_id: resource.id, service_id: service_item.id,
                                                                  starts_at: starts_at, ends_at: ends_at }))

      expect(task).to include('status' => 'pending_operator_approval', 'title' => 'Создать задачу')
      expect(task['message']).to start_with(
        'NOT executed. Waiting for operator approval (Allow / Deny): «Создать задачу» (not an appointment: it books, moves or cancels ' \
        'nothing). Cards waiting in this run: «Создать задачу» (create_task: Задача: Перезвонить пациенту).'
      )
      expect(booking['message']).to start_with(
        'NOT executed. Waiting for operator approval (Allow / Deny): «Записать на приём» (a new appointment booking). ' \
        'Cards waiting in this run: «Создать задачу» (create_task: Задача: Перезвонить пациенту), ' \
        "«Записать на приём» (create_appointment: #{booking['summary']})."
      )
      expect(booking['summary']).to include('Специалист: Д-р Смит', 'Дата и время: ')
      expect(booking['message']).to end_with('mention a booking, change or cancellation only when its card is listed.')
    end

    # The draft once promised one time while the operator approved a card with another, and an operator who approved both cards
    # booked the visit twice: the second booking of the same patient with the same specialist and service at a corrected time
    # withdraws the first card, and the agent and the operator see only the new one.
    it 'replaces the booking card of a run when the agent books the same patient with the same specialist and service at another time',
       :aggregate_failures do
      wrapper = Captain::Runtime::ToolWrapper.new(create_tool, run_context)
      first_args = { resource_id: resource.id, service_id: service_item.id, starts_at: starts_at, ends_at: ends_at }

      first = JSON.parse(wrapper.call(first_args))
      second = JSON.parse(wrapper.call(first_args.merge(starts_at: later_starts_at, ends_at: later_ends_at)))

      expect(second).to include('status' => 'pending_operator_approval')
      expect(second['message']).to include(
        "It replaces «Записать на приём» (create_appointment: #{first['summary']}): that card is withdrawn",
        "Cards waiting in this run: «Записать на приём» (create_appointment: #{second['summary']})."
      )
      expect(run_context.context[described_class::CONTEXT_KEY].pluck('action_id')).to eq([second['action_id']])
      expect(run_context.context[described_class::SUPERSEDED_CONTEXT_KEY]).to eq([first['action_id']])
      expect(described_class.pending_for(account_id: account.id, conversation_id: conversation.id).pluck('action_id'))
        .to eq([second['action_id']])
      expect(described_class.fetch_record(first['action_id'])).to include('status' => 'rejected', 'rejected_reason' => 'superseded_in_run')
      expect(account.scheduling_appointments.count).to eq(0)

      # Back to the first time: the withdrawn card is not answered again; a new card is prepared and replaces the second one.
      third = JSON.parse(wrapper.call(first_args))

      expect(third['action_id']).not_to eq(first['action_id'])
      expect(third['summary']).to eq(first['summary'])
      expect(run_context.context[described_class::CONTEXT_KEY].pluck('action_id')).to eq([third['action_id']])
      expect(described_class.pending_for(account_id: account.id, conversation_id: conversation.id).pluck('action_id'))
        .to eq([third['action_id']])
    end

    # One message may book the same patient for two visits (an ultrasound and an endocrinologist the same day): a booking with another
    # specialist or service is a card of its own, every card waits for the operator, and the agent is told about all of them.
    it 'prepares a card of its own for a booking of the same patient with another specialist or service', :aggregate_failures do
      thyroid_ultrasound = account.scheduling_services.create!(name: 'УЗИ щитовидной железы', duration_min: 30, base_price: 8_000, active: true)
      wrapper = Captain::Runtime::ToolWrapper.new(create_tool, run_context)
      first_args = { resource_id: resource.id, service_id: service_item.id, starts_at: starts_at, ends_at: ends_at }

      first = JSON.parse(wrapper.call(first_args))
      other_doctor = JSON.parse(wrapper.call(first_args.merge(resource_id: create_endocrinologist.id)))
      later_args = { starts_at: later_starts_at, ends_at: later_ends_at }
      other_service = JSON.parse(wrapper.call(first_args.merge(service_id: thyroid_ultrasound.id, **later_args)))

      cards = [first, other_doctor, other_service]
      expect(cards.pluck('status')).to all(eq('pending_operator_approval'))
      expect(cards.map { |card| card['message'] }.grep(/It replaces/)).to be_empty
      expect(other_service['message']).to include(
        "Cards waiting in this run: #{cards.map { |card| "«Записать на приём» (create_appointment: #{card['summary']})" }.join(', ')}."
      )
      expect(run_context.context[described_class::CONTEXT_KEY].pluck('action_id')).to eq(cards.pluck('action_id'))
      expect(run_context.context[described_class::SUPERSEDED_CONTEXT_KEY]).to be_blank
      expect(described_class.pending_for(account_id: account.id, conversation_id: conversation.id).pluck('action_id'))
        .to match_array(cards.pluck('action_id'))
    end

    # The manager sent the draft of an earlier suggestion, and its booking card still waits. The next suggestion books the same patient
    # with the same specialist and service at another time: the kept card is withdrawn, so that one card of that booking waits, and a
    # kept card of another specialist stays. If the new card goes unused (the suggestion is dismissed), the kept card waits again.
    it 'replaces the kept booking card of an earlier suggestion of the same specialist and service, and gives it back when the new card goes',
       :aggregate_failures do
      Current.user = user
      args = { resource_id: resource.id, service_id: service_item.id, starts_at: starts_at, ends_at: ends_at }
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 60
      kept, kept_other = Captain::ReplySuggestion::RunControl.with(request_id: 'request-1', deadline: deadline) do
        [args, args.merge(resource_id: create_endocrinologist.id)].map do |arguments|
          JSON.parse(described_class.intercept(tool: create_tool, tool_context: tool_context, arguments: arguments))
        end
      end
      described_class.keep_for_request!(account_id: account.id, conversation_id: conversation.id, request_id: 'request-1')

      next_context = Captain::Runtime::ToolContext.new(run_context: Captain::Runtime::RunContext.new(
        run_context.context.deep_dup.merge(captain_suggestion_pending_actions: [])
      ))
      # The next suggestion corrects the time, and then corrects it once more in the same run.
      later_times = [[later_starts_at, later_ends_at], [2.days.from_now.change(hour: 13, min: 0, sec: 0).iso8601, nil]]
      corrected, recorrected = Captain::ReplySuggestion::RunControl.with(request_id: 'request-2', deadline: deadline) do
        later_times.map do |from, to|
          JSON.parse(described_class.intercept(tool: create_tool, tool_context: next_context,
                                               arguments: args.merge(starts_at: from, ends_at: to).compact))
        end
      end

      kept_label = "«Записать на приём» (create_appointment: #{kept['summary']})"
      expect(corrected['message']).to include("It replaces #{kept_label}: that card is withdrawn")
      expect(recorrected['message']).to include("It replaces «Записать на приём» (create_appointment: #{corrected['summary']}), #{kept_label}")
      expect(next_context.context[described_class::SUPERSEDED_CONTEXT_KEY]).to contain_exactly(kept['action_id'], corrected['action_id'])
      expect(described_class.fetch_record(corrected['action_id'])).to include('status' => 'rejected', 'rejected_reason' => 'superseded_in_run')
      expect(described_class.fetch_record(kept['action_id'])).to include(
        'status' => 'rejected', 'rejected_reason' => 'superseded_by_later_booking', 'superseded_by' => recorrected['action_id']
      )
      expect(described_class.pending_for(account_id: account.id, conversation_id: conversation.id, request_id: 'request-2').pluck('action_id'))
        .to eq([recorrected['action_id'], kept_other['action_id']])
      expect { described_class.new(account: account, user: user).approve!(action_id: kept['action_id']) }
        .to raise_error(described_class::InvalidStateError, /replaced by a corrected card/)

      # The manager dismisses the new suggestion: its card goes, and the kept card that the patient read about waits again.
      described_class.discard_for_request!(account_id: account.id, conversation_id: conversation.id, request_id: 'request-2',
                                           reason: 'suggestion_dismissed')

      expect(described_class.fetch_record(kept['action_id'])).to include('status' => 'pending', 'kept_at' => be_present)
      expect(described_class.fetch_record(kept['action_id']).keys).not_to include('superseded_by', 'rejected_reason')
      expect(described_class.pending_for(account_id: account.id, conversation_id: conversation.id, request_id: 'request-3').pluck('action_id'))
        .to contain_exactly(kept['action_id'], kept_other['action_id'])
    ensure
      Current.reset
    end

    # The model rebuilds the patient from the chat in every suggestion: a relative's later booking may add the birth date or write the
    # surname apart, and the conversation person may be named in one call and left out in another. The same person is the same
    # booking, so the kept card is replaced, while another relative with the same specialist and service keeps a card of its own.
    it 'replaces the kept booking card of the same patient written otherwise, and keeps the card of another relative', :aggregate_failures do
      args = { resource_id: resource.id, service_id: service_item.id, starts_at: starts_at, ends_at: ends_at }
      later = { starts_at: later_starts_at, ends_at: later_ends_at }
      kept_daughter, kept_son, kept_own = suggest_bookings(
        'request-1', tool_context,
        args.merge(patient: { first_name: 'Айгуль', last_name: 'Сериккызы' }),
        args.merge(patient: { first_name: 'Нурлан', last_name: 'Серикулы' }),
        args
      )
      keep_suggestion!('request-1')

      daughter, own = suggest_bookings(
        'request-2', next_suggestion_context,
        args.merge(patient: { first_name: 'айгуль', last_name: 'Серик кызы', birth_date: '2015-03-01' }, **later),
        args.merge(patient: { first_name: 'Иван', last_name: 'Петров' }, **later)
      )

      expect([kept_daughter, kept_son, kept_own].map { |card| card['message'] }.grep(/It replaces/)).to be_empty
      expect(daughter['message']).to include("It replaces «Записать на приём» (create_appointment: #{kept_daughter['summary']}): that card")
      expect(own['message']).to include("It replaces «Записать на приём» (create_appointment: #{kept_own['summary']}): that card")
      expect(own['message']).not_to include(kept_son['summary'])
      expect(described_class.fetch_record(kept_daughter['action_id'])).to include('status' => 'rejected', 'superseded_by' => daughter['action_id'])
      expect(described_class.fetch_record(kept_own['action_id'])).to include('status' => 'rejected', 'superseded_by' => own['action_id'])
      expect(pending_ids('request-2')).to contain_exactly(daughter['action_id'], own['action_id'], kept_son['action_id'])
    end

    it 'withdraws only a card that the run itself prepared' do
      args = { resource_id: resource.id, service_id: service_item.id, starts_at: starts_at, ends_at: ends_at }
      earlier = JSON.parse(described_class.intercept(tool: create_tool, tool_context: tool_context, arguments: args))
      later_args = args.merge(starts_at: 2.days.from_now.change(hour: 11, min: 30, sec: 0).iso8601,
                              ends_at: 2.days.from_now.change(hour: 12, min: 0, sec: 0).iso8601)

      later = Captain::ReplySuggestion::RunControl.with(request_id: 'req-2', deadline: Process.clock_gettime(Process::CLOCK_MONOTONIC) + 60) do
        JSON.parse(described_class.intercept(tool: create_tool, tool_context: tool_context, arguments: later_args,
                                             replaces: [earlier['action_id']]))
      end

      expect(later['message']).not_to include('It replaces')
      expect(described_class.pending_for(account_id: account.id, conversation_id: conversation.id).pluck('action_id'))
        .to contain_exactly(earlier['action_id'], later['action_id'])
    end

    it 'stores the proposal for a service with no specialist link when the account has no links at all' do
      Scheduling::ServicePrice.where(account_id: account.id).delete_all
      args = { resource_id: resource.id, service_id: service_item.id, starts_at: starts_at, ends_at: ends_at }

      result = JSON.parse(described_class.intercept(tool: create_tool, tool_context: tool_context, arguments: args))

      expect(result['status']).to eq('pending_operator_approval')
      expect(result['details']).to include(hash_including('label' => 'Услуга', 'value' => 'Консультация терапевта'))
      expect(described_class.pending_for(account_id: account.id, conversation_id: conversation.id).size).to eq(1)
    end

    it 'deduplicates identical tool calls within the same reply_suggestion run' do
      args = {
        resource_id: resource.id,
        service_id: service_item.id,
        starts_at: starts_at,
        ends_at: ends_at
      }

      first = JSON.parse(described_class.intercept(tool: create_tool, tool_context: tool_context, arguments: args))
      second = JSON.parse(described_class.intercept(tool: create_tool, tool_context: tool_context, arguments: args))

      expect(second['action_id']).to eq(first['action_id'])
      expect(run_context.context[described_class::CONTEXT_KEY].size).to eq(1)
    end

    it 'fingerprints the action, not the agent that prepared it: the same action of another agent is one card' do
      other_agent = create(:captain_assistant, account: account, name: 'Процедуры', active: true, config: assistant.config)
      args = { resource_id: resource.id, service_id: service_item.id, starts_at: starts_at, ends_at: ends_at }

      first = JSON.parse(described_class.intercept(tool: create_tool, tool_context: tool_context, arguments: args))
      other_context = Captain::Runtime::ToolContext.new(run_context: Captain::Runtime::RunContext.new(
        run_context.context.deep_dup.merge(captain_suggestion_pending_actions: []).tap { |item| item[:state][:assistant_id] = other_agent.id }
      ))
      second = JSON.parse(described_class.intercept(tool: Captain::Tools::CreateAppointmentTool.new(other_agent), tool_context: other_context,
                                                    arguments: args))

      pending = described_class.pending_for(account_id: account.id, conversation_id: conversation.id)
      expect(described_class.fetch_record(second['action_id'])['digest']).to eq(described_class.fetch_record(first['action_id'])['digest'])
      expect(pending.size).to eq(1)
    end

    it 'records the suggestion request and the manager of the card, and lists the cards of one request' do
      Current.user = user
      args = { resource_id: resource.id, service_id: service_item.id, starts_at: starts_at, ends_at: ends_at }
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 60
      result = Captain::ReplySuggestion::RunControl.with(request_id: 'request-1', deadline: deadline) do
        JSON.parse(described_class.intercept(tool: create_tool, tool_context: tool_context, arguments: args))
      end

      expect(described_class.fetch_record(result['action_id'])).to include('suggestion_request_id' => 'request-1', 'user_id' => user.id)
      expect(described_class.pending_for(account_id: account.id, conversation_id: conversation.id, request_id: 'request-1').size).to eq(1)
      expect(described_class.pending_for(account_id: account.id, conversation_id: conversation.id, request_id: 'request-2')).to be_empty
    ensure
      Current.reset
    end

    it 'shows the kept card of an inserted suggestion instead of preparing the same action a second time' do
      Current.user = user
      args = { resource_id: resource.id, service_id: service_item.id, starts_at: starts_at, ends_at: ends_at }
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 60
      first = Captain::ReplySuggestion::RunControl.with(request_id: 'request-1', deadline: deadline) do
        JSON.parse(described_class.intercept(tool: create_tool, tool_context: tool_context, arguments: args))
      end
      described_class.keep_for_request!(account_id: account.id, conversation_id: conversation.id, request_id: 'request-1')

      next_context = Captain::Runtime::ToolContext.new(run_context: Captain::Runtime::RunContext.new(
        run_context.context.deep_dup.merge(captain_suggestion_pending_actions: [])
      ))
      control = nil
      second = Captain::ReplySuggestion::RunControl.with(request_id: 'request-2', deadline: deadline) do |run_control|
        control = run_control
        JSON.parse(described_class.intercept(tool: create_tool, tool_context: next_context, arguments: args))
      end

      expect(second['action_id']).to eq(first['action_id'])
      expect(control.action_ids).to be_empty
      expect(described_class.pending_for(account_id: account.id, conversation_id: conversation.id, request_id: 'request-2').pluck('action_id'))
        .to eq([first['action_id']])
    ensure
      Current.reset
    end

    it 'returns failure without storing a pending proposal when resource_id is invalid' do
      raw_result = described_class.intercept(
        tool: create_tool,
        tool_context: tool_context,
        arguments: {
          resource_id: 999_999,
          service_id: 999_999,
          starts_at: starts_at
        }
      )

      parsed = JSON.parse(raw_result)
      expect(parsed['success']).to be(false)
      expect(described_class.pending_for(account_id: account.id, conversation_id: conversation.id)).to be_empty
    end

    it 'returns already_booked without storing a pending proposal when slot is already booked for contact' do
      existing = account.scheduling_appointments.create!(
        contact: contact,
        client_name: 'Иван Петров',
        resource: resource,
        service: service_item,
        starts_at: Time.zone.parse(starts_at),
        ends_at: Time.zone.parse(ends_at),
        status: 'scheduled'
      )

      raw_result = described_class.intercept(
        tool: create_tool,
        tool_context: tool_context,
        arguments: {
          resource_id: resource.id,
          service_id: service_item.id,
          starts_at: starts_at,
          ends_at: ends_at
        }
      )

      parsed = JSON.parse(raw_result)
      expect(parsed['status']).to eq('already_booked')
      expect(parsed['appointment_id']).to eq(existing.id)
      expect(described_class.pending_for(account_id: account.id, conversation_id: conversation.id)).to be_empty
    end

    it 'returns time_taken without storing a pending proposal when slot is occupied by another patient' do
      other_contact = create(:contact, account: account, name: 'Мария Сидорова', phone_number: '+77019998877')
      account.scheduling_appointments.create!(
        contact: other_contact,
        client_name: 'Мария Сидорова',
        resource: resource,
        service: service_item,
        starts_at: Time.zone.parse(starts_at),
        ends_at: Time.zone.parse(ends_at),
        status: 'scheduled'
      )

      raw_result = described_class.intercept(
        tool: create_tool,
        tool_context: tool_context,
        arguments: {
          resource_id: resource.id,
          service_id: service_item.id,
          starts_at: starts_at,
          ends_at: ends_at
        }
      )

      parsed = JSON.parse(raw_result)
      expect(parsed['success']).to be(false)
      expect(parsed['reason']).to eq('time_taken')
      expect(described_class.pending_for(account_id: account.id, conversation_id: conversation.id)).to be_empty
    end
  end

  # The proposal is checked against the same visit length that slot search offers and the booking writes (Scheduling::VisitDuration).
  # For a MedElement service that is the history median in whole slots of the specialist, never the 30 minutes column default.
  describe '.intercept for a MedElement service' do
    let(:ultrasound) do
      create(:scheduling_service, account: account, name: 'УЗИ малого таза', duration_min: 30,
                                  custom_attributes: { 'medelement_nomenclature_code' => 'U1' })
    end
    let(:doctor) do
      create(:scheduling_resource, account: account, name: 'Д-р Анар', timezone: 'Asia/Almaty', slot_duration_min: 15,
                                   custom_attributes: { 'medelement_specialist_code' => 'D1' })
    end

    def create_tool
      Captain::Tools::CreateAppointmentTool.new(assistant)
    end

    # Monday of the coming week, in the time zone of the specialists
    def day
      Date.current.next_occurring(:monday)
    end

    def at(hour, minute)
      ActiveSupport::TimeZone['Asia/Almaty'].local(day.year, day.month, day.day, hour, minute)
    end

    def pair(resource, median:)
      create(:scheduling_resource_service_stat, account: account, resource: resource, service: ultrasound, median_duration_min: median)
    end

    def book(resource, from, to, **attributes)
      create(:scheduling_appointment, account: account, resource: resource, service: service_item, starts_at: from, ends_at: to,
                                      duration_min: ((to - from) / 60).to_i, **attributes)
    end

    def propose(resource, starts_at)
      arguments = { resource_id: resource.id, service_id: ultrasound.id, starts_at: starts_at.iso8601 }
      JSON.parse(described_class.intercept(tool: create_tool, tool_context: tool_context, arguments: arguments))
    end

    def pending_count
      described_class.pending_for(account_id: account.id, conversation_id: conversation.id).size
    end

    it 'sizes the booking by the median of the pair, so a slot just before another visit can be proposed' do
      pair(doctor, median: 10)
      book(doctor, at(9, 15), at(9, 30))

      result = propose(doctor, at(9, 0))

      expect(result['status']).to eq('pending_operator_approval')
      expect(pending_count).to eq(1)
    end

    it 'sizes the booking by the slot of the specialist when the pair is unknown' do
      book(doctor, at(9, 15), at(9, 30))

      expect(propose(doctor, at(9, 0))['status']).to eq('pending_operator_approval')
    end

    it 'refuses a start whose real length runs into the next visit, though the default 30 minutes would fit' do
      pair(doctor, median: 60)
      book(doctor, at(9, 45), at(10, 0))

      result = propose(doctor, at(9, 0))

      expect(result).to include('success' => false, 'reason' => 'time_taken')
      expect(pending_count).to eq(0)
    end

    it 'accepts every slot that slot search offers on a specialist with work hours, the last one before closing included' do
      plain_doctor = create(:scheduling_resource, account: account, name: 'Д-р Берик', timezone: 'Asia/Almaty', slot_duration_min: 15)
      create(:scheduling_work_rule, account: account, resource: plain_doctor, weekday: day.wday, start_minute: 9 * 60, end_minute: 10 * 60)
      pair(plain_doctor, median: 10)
      book(plain_doctor, at(9, 15), at(9, 30))

      slots = Scheduling::AvailableSlotSearchService.new(
        account: account, from: at(9, 0), to: at(10, 0), service_id: ultrasound.id, resource_ids: [plain_doctor.id], limit: 50
      ).perform[:slots]
      starts = slots.map { |slot| slot[:starts_at] }

      expect(starts).to include(at(9, 0).iso8601, at(9, 45).iso8601)
      starts.each do |starts_at|
        result = JSON.parse(
          described_class.intercept(
            tool: create_tool, tool_context: tool_context,
            arguments: { resource_id: plain_doctor.id, service_id: ultrasound.id, starts_at: starts_at }
          )
        )
        expect(result['status']).to eq('pending_operator_approval'), "slot #{starts_at} was offered but refused: #{result}"
      end
    end

    it 'sizes a change of the service by the same length' do
      pair(doctor, median: 10)
      appointment = book(doctor, at(11, 0), at(11, 30), contact: contact)
      book(doctor, at(10, 15), at(10, 30))
      token = Captain::Tools::Agent::AppointmentAccess.issue(assistant: assistant, conversation: conversation, appointment: appointment)

      raw = described_class.intercept(
        tool: Captain::Tools::UpdateAppointmentTool.new(assistant), tool_context: tool_context,
        arguments: {
          appointment_id: appointment.id, appointment_access_token: token, patient_confirmed: true,
          service_id: ultrasound.id, starts_at: at(10, 0).iso8601
        }
      )

      expect(JSON.parse(raw)['status']).to eq('pending_operator_approval')
    end
  end

  describe '#approve!' do
    subject(:approval_service) do
      described_class.new(account: account, user: user, conversation_display_id: conversation.display_id)
    end

    let(:create_tool) { Captain::Tools::CreateAppointmentTool.new(assistant) }
    let(:intercepted_record) do
      raw = described_class.intercept(
        tool: create_tool,
        tool_context: tool_context,
        arguments: {
          resource_id: resource.id,
          service_id: service_item.id,
          starts_at: starts_at,
          ends_at: ends_at
        }
      )
      action_id = JSON.parse(raw)['action_id']
      described_class.fetch_record(action_id)
    end

    it 'executes the tool upon operator approval, extracts doctor_name into result_summary, and records done action in AgentSession' do
      action_id = intercepted_record['action_id']
      digest = intercepted_record['digest']

      tool_double = instance_double(Captain::Tools::CreateAppointmentTool, name: 'create_appointment')
      allow(Captain::Tools::CreateAppointmentTool).to receive(:new).with(assistant).and_return(tool_double)
      allow(tool_double).to receive(:execute).and_return(
        JSON.generate(
          success: true,
          action: 'create_appointment',
          appointment_id: 777,
          doctor_name: 'Д-р Смит',
          local_date: '2026-10-25',
          local_time: '10:00',
          status: 'created',
          appointment: { id: 777, service_name_snapshot: 'Консультация терапевта', starts_at: starts_at }
        )
      )

      approved = approval_service.approve!(action_id: action_id, digest: digest)

      expect(approved['status']).to eq('approved')
      expect(approved['result_summary']).to eq('Д-р Смит — 2026-10-25, 10:00')

      session = Captain::Conversation::AgentSession.new(entry: assistant, conversation: conversation.reload)
      expect(session.read['done']).to be_present

      # Subsequent approve! call is idempotent
      second = approval_service.approve!(action_id: action_id, digest: digest)
      expect(second['status']).to eq('approved')
      expect(tool_double).to have_received(:execute).once
    end

    it 'refreshes appointment_access_token on approve! when target appointment snapshot still matches' do
      other_patient = create(:contact, account: account, name: 'Ребёнок Петров')
      appointment = account.scheduling_appointments.create!(
        contact: contact,
        patient_contact: other_patient,
        client_name: 'Ребёнок Петров',
        resource: resource,
        service: service_item,
        starts_at: Time.zone.parse(starts_at),
        ends_at: Time.zone.parse(ends_at),
        status: 'scheduled'
      )
      token = Captain::Tools::Agent::AppointmentAccess.issue(
        assistant: assistant,
        conversation: conversation,
        appointment: appointment
      )
      cancel_tool = Captain::Tools::CancelAppointmentTool.new(assistant)
      raw = described_class.intercept(
        tool: cancel_tool,
        tool_context: tool_context,
        arguments: {
          appointment_id: appointment.id,
          appointment_access_token: token,
          patient_confirmed: true
        }
      )
      action_id = JSON.parse(raw)['action_id']

      approved = approval_service.approve!(action_id: action_id)
      expect(approved['status']).to eq('approved')
      expect(appointment.reload.status).to eq('cancelled')
    end

    # Both cards of a corrected booking reached the operator once, and approving both booked the visit twice: the replaced card is
    # refused without running anything, and the card that replaced it books the visit once.
    it 'refuses to approve a booking card that a corrected booking replaced, and books the corrected one' do
      wrapper = Captain::Runtime::ToolWrapper.new(create_tool, run_context)
      args = { resource_id: resource.id, service_id: service_item.id, starts_at: starts_at, ends_at: ends_at }
      replaced = JSON.parse(wrapper.call(args))
      corrected = JSON.parse(wrapper.call(args.merge(starts_at: later_starts_at, ends_at: later_ends_at)))
      tool_double = instance_double(Captain::Tools::CreateAppointmentTool, name: 'create_appointment')
      allow(Captain::Tools::CreateAppointmentTool).to receive(:new).with(assistant).and_return(tool_double)
      allow(tool_double).to receive(:execute).and_return(
        JSON.generate(success: true, action: 'create_appointment', appointment_id: 778, doctor_name: 'Д-р Смит', local_time: '11:30',
                      status: 'created')
      )

      expect { approval_service.approve!(action_id: replaced['action_id']) }
        .to raise_error(described_class::InvalidStateError, /replaced by a corrected card/)
      expect(described_class.fetch_record(replaced['action_id'])).to include('status' => 'rejected', 'rejected_reason' => 'superseded_in_run')

      approved = approval_service.approve!(action_id: corrected['action_id'])

      expect(approved['status']).to eq('approved')
      expect(tool_double).to have_received(:execute).once
      expect(tool_double).to have_received(:execute).with(anything, hash_including(starts_at: later_starts_at))
    end

    it 'raises InvalidStateError when digest does not match' do
      expect do
        approval_service.approve!(
          action_id: intercepted_record['action_id'],
          digest: 'tampered-digest'
        )
      end.to raise_error(described_class::InvalidStateError, /do not match/)
    end

    it 'raises ForbiddenError when operator does not have access to the conversation' do
      other_agent = create(:user, account: account, role: :agent)
      allow(Conversations::PermissionFilterService).to receive(:new).and_return(
        instance_double(Conversations::PermissionFilterService, perform: Conversation.none)
      )

      other_service = described_class.new(account: account, user: other_agent, conversation_display_id: conversation.display_id)
      expect do
        other_service.approve!(action_id: intercepted_record['action_id'])
      end.to raise_error(described_class::ForbiddenError)
    end
  end

  describe '#reject!' do
    subject(:approval_service) do
      described_class.new(account: account, user: user, conversation_display_id: conversation.display_id)
    end

    let(:create_tool) { Captain::Tools::CreateAppointmentTool.new(assistant) }

    it 'marks the pending action as rejected without executing the tool' do
      raw = described_class.intercept(
        tool: create_tool,
        tool_context: tool_context,
        arguments: {
          resource_id: resource.id,
          service_id: service_item.id,
          starts_at: starts_at,
          ends_at: ends_at
        }
      )
      action_id = JSON.parse(raw)['action_id']

      expect(Captain::Tools::CreateAppointmentTool).not_to receive(:new)

      rejected = approval_service.reject!(action_id: action_id)

      expect(rejected['status']).to eq('rejected')
      expect(described_class.pending_for(account_id: account.id, conversation_id: conversation.id)).to be_empty
    end

    context 'with a booking card that replaced the kept card of an earlier suggestion' do
      # The 10:00 card of a sent draft (request-1), and the 11:30 card of the next suggestion (request-2) that replaced it.
      def kept_and_corrected
        args = { resource_id: resource.id, service_id: service_item.id, starts_at: starts_at, ends_at: ends_at }
        kept = suggest_bookings('request-1', tool_context, args).first
        keep_suggestion!('request-1')
        [kept, suggest_bookings('request-2', next_suggestion_context, args.merge(starts_at: later_starts_at, ends_at: later_ends_at)).first]
      end

      # The agent read "is 11:30 free too?" as a change, and the panel showed only the 11:30 card. The manager denies it before the
      # draft is inserted: the 10:00 booking the patient was told about waits for the operator again instead of being silently gone.
      it 'gives the kept card back when the operator denies the card before its draft reached the patient', :aggregate_failures do
        kept, corrected = kept_and_corrected
        expect(pending_ids('request-2')).to eq([corrected['action_id']])

        approval_service.reject!(action_id: corrected['action_id'])

        expect(described_class.fetch_record(corrected['action_id'])).to include('status' => 'rejected', 'rejected_by_id' => user.id)
        expect(described_class.fetch_record(kept['action_id'])).to include('status' => 'pending', 'kept_at' => be_present)
        expect(described_class.fetch_record(kept['action_id']).keys).not_to include('superseded_by', 'rejected_reason', 'rejected_at')
        expect(pending_ids('request-3')).to eq([kept['action_id']])
      end

      # The manager sent the 11:30 draft, so the patient read 11:30 last: denying that card does not bring 10:00 back.
      it 'keeps the replaced card withdrawn when the operator denies a kept card', :aggregate_failures do
        kept, corrected = kept_and_corrected
        keep_suggestion!('request-2')

        approval_service.reject!(action_id: corrected['action_id'])

        expect(described_class.fetch_record(kept['action_id'])).to include(
          'status' => 'rejected', 'rejected_reason' => 'superseded_by_later_booking', 'superseded_by' => corrected['action_id']
        )
        expect(pending_ids('request-3')).to be_empty
        expect { approval_service.approve!(action_id: kept['action_id']) }
          .to raise_error(described_class::InvalidStateError, /replaced by a corrected card/)
      end
    end
  end
end
