module BulkActionsJob::RecordProcessor
  def available_params(params)
    return unless params[:fields]

    params[:fields].dup.delete_if { |key, value| value.nil? && key.to_s == 'status' }
  end

  def bulk_add_labels(conversation)
    conversation.add_labels(@params[:labels][:add]) if @params[:labels] && @params[:labels][:add]
  end

  def bulk_snoozed_until(conversation)
    conversation.snoozed_until = parse_date_time(@params[:snoozed_until].to_s) if @params[:snoozed_until]
  end

  def remove_labels(conversation)
    return unless @params[:labels] && @params[:labels][:remove]

    labels = conversation.label_list - @params[:labels][:remove]
    conversation.update!(label_list: labels)
  end

  def process_conversation(conversation)
    remove_labels(conversation)
    bulk_add_labels(conversation)

    params = available_params(@params)
    if status_update_params?(params)
      transition_conversation_status!(conversation, params)
      params = params.except(:status, :status_reason)
    else
      bulk_snoozed_until(conversation)
    end

    conversation.update!(params) if params.present?

    return unless @params[:action_name] == 'mark_read'

    Conversations::MarkReadService.new(
      conversation: conversation,
      user: Current.user
    ).perform
  end

  def process_communication_thread(communication_thread)
    accessible_links = accessible_links_for(communication_thread)
    raise BulkActionsJob::SkippedRecord, 'No accessible channels remain' if accessible_links.empty?

    params = communication_thread_update_params
    validate_thread_update!(communication_thread, accessible_links, params) if params.present?

    bulk_remove_thread_labels(accessible_links)
    bulk_add_thread_labels(accessible_links)

    update_thread(communication_thread, accessible_links, params) if params.present?

    return unless @params[:action_name] == 'mark_read'

    mark_thread_read(communication_thread, accessible_links)
  end

  def update_thread(communication_thread, accessible_links, params)
    CommunicationThreads::UpdateService.new(
      communication_thread: communication_thread,
      params: params,
      accessible_links: accessible_links,
      actor: @user,
      source: 'bulk_action'
    ).perform
  end

  def mark_thread_read(communication_thread, accessible_links)
    CommunicationThreads::MarkReadService.new(
      communication_thread: communication_thread,
      current_user: Current.user,
      current_account: @account,
      accessible_links: accessible_links
    ).perform
  end

  def validate_thread_update!(communication_thread, accessible_links, params)
    ensure_full_thread_accessible!(communication_thread, accessible_links)
    return unless params[:status].to_s == 'resolved'

    accessible_links.each { |link| skip_for_missing_required_attributes!(link.conversation) }
  end

  def process_record(record)
    raise BulkActionsJob::SkippedRecord, 'User is no longer a member of the account' unless account_member?

    if record.is_a?(Conversation)
      accessible = Conversations::PermissionFilterService.new(
        Conversation.where(id: record.id, account_id: @account.id),
        @user,
        @account
      ).perform.exists?
      raise BulkActionsJob::SkippedRecord, 'Conversation access was revoked' unless accessible

      skip_for_missing_required_attributes!(record) if resolved_status_requested?
    end

    if record.is_a?(CommunicationThread)
      process_communication_thread(record)
    else
      process_conversation(record)
    end
  end
end
