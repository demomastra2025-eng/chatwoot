require 'rails_helper'

RSpec.describe Scheduling::AppointmentDialogContextLoader do
  let(:account) { create(:account) }
  let(:resource) { create(:scheduling_resource, account: account) }

  it 'bulk resolves a contact thread and its primary conversation' do
    contact = create(:contact, account: account)
    conversation = create(:conversation, account: account, contact: contact)
    thread = create(:communication_thread, account: account, contact: contact)
    create(
      :communication_thread_conversation,
      account: account,
      communication_thread: thread,
      conversation: conversation,
      primary: true
    )
    appointment = create(
      :scheduling_appointment,
      account: account,
      resource: resource,
      contact: contact,
      conversation: nil
    )

    context = described_class.new([appointment]).perform

    expect(context.fetch(appointment.id)).to include(
      chat_conversation: conversation,
      communication_thread: thread
    )
  end

  it 'uses the latest contact conversation when no communication thread exists' do
    contact = create(:contact, account: account)
    older_conversation = create(
      :conversation,
      account: account,
      contact: contact,
      last_activity_at: 2.days.ago
    )
    latest_conversation = create(
      :conversation,
      account: account,
      contact: contact,
      last_activity_at: 1.day.ago
    )
    appointment = create(
      :scheduling_appointment,
      account: account,
      resource: resource,
      contact: contact,
      conversation: nil
    )

    context = described_class.new([appointment]).perform

    expect(context.fetch(appointment.id)).to include(
      chat_conversation: latest_conversation,
      communication_thread: nil
    )
    expect(context.dig(appointment.id, :chat_conversation)).not_to eq(older_conversation)
  end

  it 'does not cross account boundaries through an inconsistent thread link' do
    contact = create(:contact, account: account)
    thread = create(:communication_thread, account: account, contact: contact)
    appointment = create(
      :scheduling_appointment,
      account: account,
      resource: resource,
      contact: contact,
      conversation: nil
    )
    other_account = create(:account)
    other_conversation = create(:conversation, account: other_account)
    malformed_link = build(
      :communication_thread_conversation,
      account: other_account,
      communication_thread: thread,
      conversation: other_conversation,
      primary: true
    )
    malformed_link.save!(validate: false)

    context = described_class.new([appointment]).perform

    expect(context.fetch(appointment.id)).to include(
      chat_conversation: nil,
      communication_thread: thread
    )
  end

  it 'preserves legacy thread fields for an available direct conversation in calendar payloads' do
    contact = create(:contact, account: account)
    conversation = create(:conversation, account: account, contact: contact)
    thread = create(:communication_thread, account: account, contact: contact)
    create(
      :communication_thread_conversation,
      account: account,
      communication_thread: thread,
      conversation: conversation,
      primary: true
    )
    appointment = create(
      :scheduling_appointment,
      account: account,
      resource: resource,
      contact: contact,
      conversation: conversation
    )
    appointments = Scheduling::Appointment
                   .where(id: appointment.id)
                   .includes(:expense, :payments, :resource, conversation: [:communication_thread, :inbox])
                   .to_a

    serialized = Scheduling::PayloadBuilder.calendar(calendar_payload(appointments))
    appointment_payload = serialized.fetch(:appointments).first

    expect(appointment_payload).to include(
      appointment_communication_thread_id: thread.id,
      communication_thread_id: thread.id,
      chat_conversation_id: conversation.id
    )
  end

  it 'keeps dialog query count bounded as appointments grow' do
    appointment_ids = Array.new(12) do
      contact = create(:contact, account: account)
      create(:conversation, account: account, contact: contact)
      create(
        :scheduling_appointment,
        account: account,
        resource: resource,
        contact: contact,
        conversation: nil
      ).id
    end
    appointments = Scheduling::Appointment
                   .where(id: appointment_ids)
                   .includes(:expense, :payments, :resource, conversation: [:communication_thread, :inbox])
                   .to_a
    dialog_queries = []
    subscriber = lambda do |*, payload|
      next if payload[:cached] || %w[SCHEMA TRANSACTION].include?(payload[:name])
      next unless payload[:sql].to_s.match?(/FROM "(?:communication_threads|communication_thread_conversations|conversations)"/)

      dialog_queries << payload[:sql]
    end

    serialized = ActiveSupport::Notifications.subscribed(subscriber, 'sql.active_record') do
      Scheduling::PayloadBuilder.calendar(calendar_payload(appointments))
    end

    expect(serialized.fetch(:appointments).size).to eq(12)
    expect(dialog_queries.size).to be <= 6
  end

  def calendar_payload(appointments)
    {
      view: 'week',
      range: {},
      resources: [],
      work_rules: [],
      break_rules: [],
      holidays: [],
      workday_overrides: [],
      time_offs: [],
      appointments: appointments,
      payments: [],
      expenses: [],
      slots: []
    }
  end
end
