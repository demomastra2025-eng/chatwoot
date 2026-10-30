# frozen_string_literal: true

module Crm::Tasks::OriginatingSourceResolver
  private

  def resolve_originating_conversation(deal:)
    return requested_originating_conversation if originating_source_param_provided?
    return task.originating_conversation if task.persisted?

    deal&.originating_conversation
  end

  def originating_source_param_provided?
    params.key?(:originating_conversation_display_id) ||
      params.key?(:originating_conversation_id) ||
      params.key?(:originating_communication_thread_id)
  end

  def requested_originating_conversation
    disp_id = params[:originating_conversation_display_id]
    return resolve_conversation_by_display_id!(disp_id) if disp_id.present?
    return resolve_conversation_by_id_or_display_id!(params[:originating_conversation_id]) if params[:originating_conversation_id].present?
    return latest_thread_conversation(requested_communication_thread) if params[:originating_communication_thread_id].present?

    nil
  end

  def resolve_conversation_by_display_id!(raw_value)
    value = raw_value.to_s.strip
    return task.originating_conversation if task.originating_conversation&.display_id.to_s == value

    account.conversations.find_by!(display_id: value)
  end

  def resolve_conversation_by_id_or_display_id!(raw_value)
    value = raw_value.to_s.strip
    return task.originating_conversation if task.originating_conversation&.id.to_s == value

    account.conversations.find_by(id: value) || account.conversations.find_by!(display_id: value)
  end

  def requested_communication_thread
    return @requested_communication_thread if defined?(@requested_communication_thread)

    value = params[:originating_communication_thread_id].to_s.strip
    scope = CommunicationThread.where(account_id: account.id)
    @requested_communication_thread = scope.find_by(display_id: value) || scope.find(value)
  end

  def latest_thread_conversation(thread)
    thread&.conversations&.order(Arel.sql('conversations.last_activity_at DESC NULLS LAST, conversations.id DESC'))&.first
  end

  def thread_default_assignee
    return if params[:originating_communication_thread_id].blank?

    thread = requested_communication_thread
    thread&.contact&.owner || thread&.assignee
  end
end
