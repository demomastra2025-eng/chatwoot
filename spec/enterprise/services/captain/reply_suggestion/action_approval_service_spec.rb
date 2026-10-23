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
  end
end
