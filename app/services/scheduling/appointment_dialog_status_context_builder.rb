# frozen_string_literal: true

class Scheduling::AppointmentDialogStatusContextBuilder
  attr_reader :account

  def initialize(account:)
    @account = account
  end

  def for_conversations(conversations)
    records = Array(conversations)
    return {} if records.blank? || scheduling_disabled?

    contexts = context_hash
    add_direct_conversation_appointments(contexts, records)
    add_contact_appointments(contexts, records_by_contact_id(records))
    contexts_to_payloads(contexts)
  end

  def for_communication_threads(communication_threads)
    records = Array(communication_threads)
    return {} if records.blank? || scheduling_disabled?

    contexts = context_hash
    add_contact_appointments(contexts, records_by_contact_id(records))
    add_conversation_appointments_for_threads(contexts, records)
    contexts_to_payloads(contexts)
  end

  private

  def context_hash
    Hash.new { |hash, key| hash[key] = {} }
  end

  def scheduling_disabled?
    !account.feature_enabled?('scheduling')
  end

  def appointment_scope
    account.scheduling_appointments.select(:id, :conversation_id, :contact_id, :status)
  end

  def add_direct_conversation_appointments(contexts, conversations)
    conversation_ids = conversations.map(&:id)
    appointment_scope.where(conversation_id: conversation_ids).find_each do |appointment|
      add_status_context(contexts, appointment.conversation_id, appointment)
    end
  end

  def add_contact_appointments(contexts, record_ids_by_contact_id)
    return if record_ids_by_contact_id.blank?

    appointment_scope.where(contact_id: record_ids_by_contact_id.keys).find_each do |appointment|
      record_ids_by_contact_id[appointment.contact_id].each do |record_id|
        add_status_context(contexts, record_id, appointment)
      end
    end
  end

  def add_conversation_appointments_for_threads(contexts, communication_threads)
    thread_ids_by_conversation_id = thread_conversation_map(communication_threads.map(&:id))
    return if thread_ids_by_conversation_id.blank?

    appointment_scope.where(conversation_id: thread_ids_by_conversation_id.keys).find_each do |appointment|
      thread_ids_by_conversation_id[appointment.conversation_id].each do |thread_id|
        add_status_context(contexts, thread_id, appointment)
      end
    end
  end

  def add_status_context(contexts, record_id, appointment)
    return if record_id.blank? || !valid_status?(appointment.status)

    contexts[record_id][appointment.status] ||= {
      status: appointment.status,
      appointment_ids: Set.new
    }
    contexts[record_id][appointment.status][:appointment_ids] << appointment.id
  end

  def contexts_to_payloads(contexts)
    contexts.transform_values do |status_contexts|
      status_contexts.values
                     .sort_by { |context| status_sort_key(context[:status]) }
                     .map { |context| status_payload(context) }
    end
  end

  def status_payload(context)
    {
      status: context[:status],
      count: context[:appointment_ids].size
    }
  end

  def status_sort_key(status)
    [Scheduling::Constants::APPOINTMENT_STATUSES.index(status) || Scheduling::Constants::APPOINTMENT_STATUSES.length, status]
  end

  def valid_status?(status)
    Scheduling::Constants::APPOINTMENT_STATUSES.include?(status)
  end

  def records_by_contact_id(records)
    records.each_with_object({}) do |record, result|
      next if record.contact_id.blank?

      result[record.contact_id] ||= []
      result[record.contact_id] << record.id
    end
  end

  def thread_conversation_map(thread_ids)
    CommunicationThreadConversation
      .where(account_id: account.id, communication_thread_id: thread_ids)
      .pluck(:conversation_id, :communication_thread_id)
      .each_with_object({}) do |(conversation_id, thread_id), result|
        result[conversation_id] ||= []
        result[conversation_id] << thread_id
      end
  end
end
