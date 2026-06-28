# frozen_string_literal: true

class Scheduling::AppointmentDialogScopeBuilder
  ANY_STATUS_FILTERS = %w[any all].freeze

  attr_reader :account, :statuses

  def initialize(account:, status: nil)
    @account = account
    @statuses = normalize_statuses(status)
  end

  def active?
    statuses.present?
  end

  def filter_conversations(scope)
    return scope unless active?

    scope.where(id: conversation_ids)
  end

  def filter_communication_threads(scope)
    return scope unless active?

    scope.where(id: communication_thread_ids)
  end

  def conversation_ids
    return account.conversations.none.select(:id) unless active?

    account.conversations.where(id: direct_conversation_ids)
           .or(account.conversations.where(contact_id: appointment_contact_ids))
           .select(:id)
  end

  def communication_thread_ids
    return CommunicationThread.none.select(:id) unless active?

    account_threads.where(contact_id: appointment_contact_ids)
                   .or(account_threads.where(id: conversation_thread_ids))
                   .select(:id)
  end

  private

  def appointment_scope
    account.scheduling_appointments.where(status: statuses)
  end

  def appointment_contact_ids
    appointment_scope.where.not(contact_id: nil).select(:contact_id)
  end

  def direct_conversation_ids
    appointment_scope.where.not(conversation_id: nil).select(:conversation_id)
  end

  def conversation_thread_ids
    CommunicationThreadConversation.where(
      account_id: account.id,
      conversation_id: direct_conversation_ids
    ).select(:communication_thread_id)
  end

  def account_threads
    CommunicationThread.where(account_id: account.id)
  end

  def normalize_statuses(value)
    values = Array(value).flat_map { |item| item.to_s.split(',') }
                         .map(&:strip)
                         .reject(&:blank?)
    return [] if values.blank?

    return Scheduling::Constants::APPOINTMENT_STATUSES if values.intersect?(ANY_STATUS_FILTERS)

    normalized = values.select { |status| Scheduling::Constants::APPOINTMENT_STATUSES.include?(status) }.uniq
    normalized.presence || ['__invalid_appointment_status__']
  end
end
