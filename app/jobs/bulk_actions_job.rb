class BulkActionsJob < ApplicationJob
  include DateRangeHelper
  include BulkActionsJob::RecordProcessor
  include BulkActionsJob::StatusAndLabels

  queue_as :medium
  attr_accessor :records

  MODEL_TYPE = %w[Conversation CommunicationThread].freeze
  PROGRESS_FLUSH_EVERY = 100

  def perform(account:, params:, user:, bulk_action_run_id: nil, selection_count: nil)
    prepare_run(account, params, user, bulk_action_run_id, selection_count)
    return if @bulk_action_run&.completed?

    execute_run
  rescue StandardError => e
    @bulk_action_run&.fail!(e.message)
    raise
  ensure
    Current.reset
  end

  def execute_run
    @records = records_for_execution(@record_ids)
    total_count = @selection_count || (@record_ids.size + @initial_skipped_count)
    @bulk_action_run&.start!(total_count: total_count)
    flush_progress(@initial_skipped_count, 0, @initial_skipped_count) if @initial_skipped_count&.positive?
    bulk_update
    @bulk_action_run&.complete!
  end

  def prepare_run(account, params, user, bulk_action_run_id, selection_count)
    @account = account
    @user = user
    Current.user = user
    @params = params.deep_symbolize_keys
    @required_attribute_definitions = nil
    @bulk_action_run = account.bulk_action_runs.find_by(id: bulk_action_run_id) if bulk_action_run_id.present?
    @selection_count = selection_count&.to_i
    @account_member_at_start = account_member?
    prepare_record_ids
  end

  def prepare_record_ids
    if @selection_count
      @record_ids = Array(@params[:record_ids]).map(&:to_i)
      raise ArgumentError, 'Bulk selection identities do not match its count' unless
        @record_ids.size == @selection_count && @record_ids.uniq == @record_ids
    else
      candidate_records = records_to_updated(@params[:ids])
      @record_ids = @account_member_at_start ? candidate_records.distinct.pluck(:id) : []
      @initial_skipped_count = [Array(@params[:ids]).uniq.size - @record_ids.size, 0].max
    end
  end

  def bulk_update
    @record_ids.each_slice(PROGRESS_FLUSH_EVERY) do |record_ids|
      failed_count, skipped_count = process_batch(record_ids)
      flush_progress(record_ids.size, failed_count, skipped_count)
    end
  end

  def process_batch(record_ids)
    records_by_id = records.where(id: record_ids).index_by(&:id)
    prepare_batch_context(record_ids)
    outcomes = record_ids.map { |id| process_selected_record(records_by_id[id], id) }
    [outcomes.count(:failed), outcomes.count(:skipped)]
  ensure
    clear_batch_context
  end

  def prepare_batch_context(record_ids)
    return unless @account && @user
    return unless (@batch_account_member = account_member?) && record_ids.present?

    if @params&.dig(:type).to_s.camelcase == 'CommunicationThread'
      prepare_thread_batch_context(record_ids)
    else
      @batch_accessible_conversation_ids = Conversations::PermissionFilterService.new(
        Conversation.where(id: record_ids, account_id: @account.id), @user, @account
      ).perform.pluck(:id).to_set
    end
  end

  def prepare_thread_batch_context(record_ids)
    scope = CommunicationThreadConversation.where(account_id: @account.id, communication_thread_id: record_ids)
    @batch_accessible_links_by_thread_id = scope.where(conversation_id: accessible_conversations.select(:id))
                                                .includes(:conversation)
                                                .group_by(&:communication_thread_id)
    @batch_total_link_counts_by_thread_id = scope.group(:communication_thread_id).count
  end

  def clear_batch_context
    @batch_account_member = nil
    @batch_accessible_links_by_thread_id = nil
    @batch_total_link_counts_by_thread_id = nil
    @batch_accessible_conversation_ids = nil
  end

  def process_selected_record(record, record_id)
    unless record
      Rails.logger.info("[BULK ACTIONS] selected record id=#{record_id} is no longer available; skipped")
      return :skipped
    end

    process_record(record)
    :done
  rescue SkippedRecord => e
    Rails.logger.info("[BULK ACTIONS] #{record.class.name}=#{record.id} skipped: #{e.message}")
    :skipped
  rescue StandardError => e
    Rails.logger.error("[BULK ACTIONS] #{record.class.name}=#{record.id} failed: #{e.class}: #{e.message}")
    :failed
  end

  def records_to_updated(ids)
    current_model = @params[:type].camelcase
    return unless MODEL_TYPE.include?(current_model)

    return conversations_to_updated(ids) if current_model == 'Conversation'

    communication_threads_to_updated(ids)
  end

  def conversations_to_updated(ids)
    scope = Conversation.where(account_id: @account.id, display_id: ids)
    Conversations::PermissionFilterService.new(scope, @user, @account).perform
  end

  def records_for_execution(ids)
    case @params[:type].to_s.camelcase
    when 'Conversation'
      @account.conversations.where(id: ids)
    when 'CommunicationThread'
      CommunicationThread.where(account_id: @account.id, id: ids)
    else
      Conversation.none
    end
  end

  def communication_threads_to_updated(ids)
    CommunicationThread
      .where(account_id: @account.id, display_id: ids)
      .joins(:communication_thread_conversations)
      .where(communication_thread_conversations: { conversation_id: accessible_conversations.select(:id) })
      .distinct
  end

  def accessible_conversations
    Conversations::PermissionFilterService.new(
      @account.conversations,
      @user,
      @account
    ).perform
  end

  def accessible_links_for(communication_thread)
    return @batch_accessible_links_by_thread_id.fetch(communication_thread.id, []) if @batch_accessible_links_by_thread_id

    CommunicationThreadConversation
      .where(account_id: @account.id, communication_thread_id: communication_thread.id)
      .where(conversation_id: accessible_conversations.select(:id))
      .includes(:conversation)
  end

  def total_link_count_for(communication_thread)
    return @batch_total_link_counts_by_thread_id.fetch(communication_thread.id, 0) if @batch_total_link_counts_by_thread_id

    communication_thread.communication_thread_conversations.count
  end

  class SkippedRecord < StandardError; end

  def account_member?
    @account.account_users.exists?(user_id: @user.id)
  end

  def batch_account_member?
    @batch_account_member.nil? ? account_member? : @batch_account_member
  end

  def flush_progress(processed_count, failed_count, skipped_count)
    return unless @bulk_action_run

    @bulk_action_run.advance!(
      processed_increment: processed_count,
      failed_increment: failed_count,
      skipped_increment: skipped_count
    )
  end
end
