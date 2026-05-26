class BulkActionsJob < ApplicationJob
  include DateRangeHelper

  queue_as :medium
  attr_accessor :records

  MODEL_TYPE = ['Conversation'].freeze
  PROGRESS_FLUSH_EVERY = 5

  def perform(account:, params:, user:, bulk_action_run_id: nil)
    @account = account
    @user = user
    Current.user = user
    @params = params.deep_symbolize_keys
    @bulk_action_run = account.bulk_action_runs.find_by(id: bulk_action_run_id) if bulk_action_run_id.present?
    @records = records_to_updated(params[:ids])
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

    records.find_each do |conversation|
      process_conversation(conversation)
    rescue StandardError => e
      failed_since_flush += 1
      Rails.logger.error("[BULK ACTIONS] conversation=#{conversation.id} failed: #{e.class}: #{e.message}")
    ensure
      processed_since_flush += 1
      if processed_since_flush >= PROGRESS_FLUSH_EVERY
        flush_progress(processed_since_flush, failed_since_flush)
        processed_since_flush = 0
        failed_since_flush = 0
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
    bulk_snoozed_until(conversation)

    params = available_params(@params)
    conversation.update!(params) if params.present?

    return unless @params[:action_name] == 'mark_read'

    Conversations::MarkReadService.new(
      conversation: conversation,
      user: Current.user
    ).perform
  end

  def records_to_updated(ids)
    current_model = @params[:type].camelcase
    return unless MODEL_TYPE.include?(current_model)

    scope = current_model.constantize&.where(account_id: @account.id, display_id: ids)
    Conversations::PermissionFilterService.new(scope, @user, @account).perform
  end

  def flush_progress(processed_count, failed_count)
    return unless @bulk_action_run

    @bulk_action_run.advance!(
      processed_increment: processed_count,
      failed_increment: failed_count
    )
  end
end
