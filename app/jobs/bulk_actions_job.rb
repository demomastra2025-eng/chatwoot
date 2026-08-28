class BulkActionsJob < ApplicationJob
  include DateRangeHelper

  queue_as :medium
  attr_accessor :records

  MODEL_TYPE = %w[Conversation CommunicationThread].freeze
  PROGRESS_FLUSH_EVERY = 25
  RECORD_BATCH_SIZE = 100

  def perform(account:, params:, user:, bulk_action_run_id: nil)
    @account = account
    @user = user
    Current.user = user
    Current.account = account
    @params = params.deep_symbolize_keys
    @bulk_action_run = account.bulk_action_runs.find_by(id: bulk_action_run_id) if bulk_action_run_id.present?
    @records = records_to_updated
    @bulk_action_run&.start!(total_count: records.count)
    bulk_update
    @bulk_action_run&.complete!
  rescue StandardError => e
    @bulk_action_run&.fail!(e.message)
    raise
  ensure
    Current.reset
  end

  def bulk_update
    processed_since_flush = 0
    failed_since_flush = 0

    records.find_in_batches(batch_size: RECORD_BATCH_SIZE) do |batch|
      preload_communication_thread_batch(batch)
      batch.each do |record|
        process_record(record)
      rescue StandardError => e
        failed_since_flush += 1
        Rails.logger.error("[BULK ACTIONS] #{record.class.name}=#{record.id} failed: #{e.class}: #{e.message}")
      ensure
        processed_since_flush += 1
        if processed_since_flush >= PROGRESS_FLUSH_EVERY
          flush_progress(processed_since_flush, failed_since_flush)
          processed_since_flush = 0
          failed_since_flush = 0
        end
      end
    end

    flush_progress(processed_since_flush, failed_since_flush) if processed_since_flush.positive?
  end

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
    params = communication_thread_update_params
    ensure_full_thread_accessible!(communication_thread, accessible_links) if params.present?

    bulk_remove_thread_labels(accessible_links)
    bulk_add_thread_labels(accessible_links)

    if params.present?
      CommunicationThreads::UpdateService.new(
        communication_thread: communication_thread,
        params: params,
        accessible_links: accessible_links,
        actor: @user,
        source: 'bulk_action'
      ).perform
    end

    return unless @params[:action_name] == 'mark_read'

    CommunicationThreads::MarkReadService.new(
      communication_thread: communication_thread,
      current_user: Current.user,
      current_account: @account,
      accessible_links: accessible_links
    ).perform
  end

  def process_record(record)
    if record.is_a?(CommunicationThread)
      process_communication_thread(record)
    else
      process_conversation(record)
    end
  end

  def records_to_updated
    current_model = @params[:type].camelcase
    return unless MODEL_TYPE.include?(current_model)

    return all_matching_records(current_model) if all_matching_selection?

    return conversations_to_updated(@params[:ids]) if current_model == 'Conversation'

    communication_threads_to_updated(@params[:ids])
  end

  def all_matching_selection?
    @params.dig(:selection, :mode) == 'all_matching'
  end

  def all_matching_records(current_model)
    unless current_model == 'CommunicationThread'
      raise ArgumentError, 'Server-side selection is only supported for communication threads'
    end

    scope = all_matching_communication_threads
    excluded_ids = Array(@params.dig(:selection, :excluded_ids)).filter_map do |id|
      Integer(id, exception: false)
    end

    excluded_ids.present? ? scope.where.not(display_id: excluded_ids) : scope
  end

  def all_matching_communication_threads
    selection = @params.fetch(:selection)
    filters = (selection[:filters] || {}).merge(include_meta: false)
    payload = Array(selection[:payload]).map { |condition| condition.to_h.with_indifferent_access }

    if payload.present?
      CommunicationThreads::FilterService.new(
        filters.merge(payload: payload),
        @user,
        @account,
        operational: true
      ).perform_scope
    else
      CommunicationThreadFinder.new(@user, filters, operational: true).perform_scope
    end
  end

  def conversations_to_updated(ids)
    scope = Conversation.where(account_id: @account.id, display_id: ids)
    Conversations::PermissionFilterService.new(scope, @user, @account).perform_operational
  end

  def communication_threads_to_updated(ids)
    CommunicationThread
      .where(account_id: @account.id, display_id: ids)
      .joins(:communication_thread_conversations)
      .where(communication_thread_conversations: { conversation_id: accessible_conversations.select(:id) })
      .distinct
  end

  def accessible_conversations
    @accessible_conversations ||= Conversations::PermissionFilterService.new(
      @account.conversations,
      @user,
      @account
    ).perform_operational
  end

  def accessible_links_for(communication_thread)
    if @accessible_links_by_thread_id
      return @accessible_links_by_thread_id.fetch(communication_thread.id, [])
    end

    CommunicationThreadConversation
      .where(account_id: @account.id, communication_thread_id: communication_thread.id)
      .where(conversation_id: accessible_conversations.select(:id))
      .includes(:conversation)
  end

  def preload_communication_thread_batch(batch)
    thread_ids = batch.filter_map { |record| record.id if record.is_a?(CommunicationThread) }
    @accessible_links_by_thread_id = nil
    @thread_link_counts_by_thread_id = nil
    return if thread_ids.blank?

    links = CommunicationThreadConversation
            .where(account_id: @account.id, communication_thread_id: thread_ids)
            .where(conversation_id: accessible_conversations.select(:id))
            .includes(:conversation)
            .to_a
    @accessible_links_by_thread_id = links.group_by(&:communication_thread_id)
    @thread_link_counts_by_thread_id = CommunicationThreadConversation
                                        .where(account_id: @account.id, communication_thread_id: thread_ids)
                                        .group(:communication_thread_id)
                                        .count
  end

  def communication_thread_update_params
    params = available_params(@params) || {}
    return params unless @params[:snoozed_until]

    params.merge(snoozed_until: @params[:snoozed_until])
  end

  def status_update_params?(params)
    params.present? && params.key?(:status)
  end

  def transition_conversation_status!(conversation, params)
    status_params = params.slice(:status, :status_reason)
    status_params[:snoozed_until] = @params[:snoozed_until] if @params.key?(:snoozed_until)

    Conversations::StatusTransitionService.new(
      conversation: conversation,
      params: status_params,
      actor: @user,
      source: 'bulk_action'
    ).perform
  end

  def ensure_full_thread_accessible!(communication_thread, accessible_links)
    total_link_count = @thread_link_counts_by_thread_id&.fetch(communication_thread.id, 0) ||
                       communication_thread.communication_thread_conversations.count
    return if accessible_links.size == total_link_count

    raise ArgumentError, 'Cannot update communication thread without access to all linked channels'
  end

  def bulk_add_thread_labels(accessible_links)
    return unless @params[:labels] && @params[:labels][:add]

    accessible_links.each do |link|
      link.conversation.add_labels(@params[:labels][:add])
    end
  end

  def bulk_remove_thread_labels(accessible_links)
    return unless @params[:labels] && @params[:labels][:remove]

    accessible_links.each do |link|
      labels = link.conversation.label_list - @params[:labels][:remove]
      link.conversation.update!(label_list: labels)
    end
  end

  def flush_progress(processed_count, failed_count)
    return unless @bulk_action_run

    @bulk_action_run.advance!(
      processed_increment: processed_count,
      failed_increment: failed_count
    )
  end
end
