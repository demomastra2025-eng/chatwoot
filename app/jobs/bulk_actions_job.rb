class BulkActionsJob < ApplicationJob
  include DateRangeHelper

  queue_as :medium
  attr_accessor :records

  MODEL_TYPE = %w[Conversation CommunicationThread].freeze
  PROGRESS_FLUSH_EVERY = 5

  def perform(account:, params:, user:, bulk_action_run_id: nil, selection_count: nil)
    @account = account
    @user = user
    Current.user = user
    @params = params.deep_symbolize_keys
    @bulk_action_run = account.bulk_action_runs.find_by(id: bulk_action_run_id) if bulk_action_run_id.present?
    @selection_count = selection_count&.to_i
    @account_member_at_start = account_member?
    if @selection_count
      @record_ids = Array(@params[:record_ids]).map(&:to_i)
      raise ArgumentError, 'Bulk selection identities do not match its count' unless
        @record_ids.size == @selection_count && @record_ids.uniq == @record_ids
    else
      candidate_records = records_to_updated(@params[:ids])
      @record_ids = @account_member_at_start ? candidate_records.distinct.pluck(:id) : []
    end

    total_count = @selection_count || @record_ids.size
    @records = records_for_execution(@record_ids)
    @bulk_action_run&.start!(total_count: total_count)
    bulk_update
    @bulk_action_run&.complete!
  rescue StandardError => e
    @bulk_action_run&.fail!(e.message)
    raise
  ensure
    Current.reset
  end

  def bulk_update
    @record_ids.each_slice(PROGRESS_FLUSH_EVERY) do |record_ids|
      records_by_id = records.where(id: record_ids).index_by(&:id)
      failed_count = 0
      skipped_count = 0

      record_ids.each do |record_id|
        record = records_by_id[record_id]
        if record.nil?
          skipped_count += 1
          Rails.logger.info("[BULK ACTIONS] selected record id=#{record_id} is no longer available; skipped")
          next
        end

        begin
          process_record(record)
        rescue SkippedRecord => e
          skipped_count += 1
          Rails.logger.info("[BULK ACTIONS] #{record.class.name}=#{record.id} skipped: #{e.message}")
        rescue StandardError => e
          failed_count += 1
          Rails.logger.error("[BULK ACTIONS] #{record.class.name}=#{record.id} failed: #{e.class}: #{e.message}")
        end
      end

      flush_progress(record_ids.size, failed_count, skipped_count)
    end
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
    raise SkippedRecord, 'No accessible channels remain' if accessible_links.empty?

    params = communication_thread_update_params
    if params.present?
      ensure_full_thread_accessible!(communication_thread, accessible_links)
      if params[:status].to_s == 'resolved'
        accessible_links.each do |link|
          skip_for_missing_required_attributes!(link.conversation)
        end
      end
    end

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
    raise SkippedRecord, 'User is no longer a member of the account' unless account_member?

    if record.is_a?(Conversation)
      accessible = Conversations::PermissionFilterService.new(
        Conversation.where(id: record.id, account_id: @account.id),
        @user,
        @account
      ).perform.exists?
      raise SkippedRecord, 'Conversation access was revoked' unless accessible

      skip_for_missing_required_attributes!(record) if resolved_status_requested?
    end

    if record.is_a?(CommunicationThread)
      process_communication_thread(record)
    else
      process_conversation(record)
    end
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
      @account.communication_threads.where(id: ids)
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
    CommunicationThreadConversation
      .where(account_id: @account.id, communication_thread_id: communication_thread.id)
      .where(conversation_id: accessible_conversations.select(:id))
      .includes(:conversation)
  end

  class SkippedRecord < StandardError; end

  def account_member?
    @account.account_users.exists?(user_id: @user.id)
  end

  def resolved_status_requested?
    Array(@params.dig(:fields, :status)).first.to_s == 'resolved'
  end

  def skip_for_missing_required_attributes!(conversation)
    return unless @account.feature_enabled?('conversation_required_attributes')

    required_keys = Array(@account.settings&.fetch('conversation_required_attributes', nil)).map(&:to_s)
    return if required_keys.empty?

    definitions = @account.custom_attribute_definitions
                          .conversation_attribute
                          .where(attribute_key: required_keys)
                          .select(:attribute_key, :attribute_display_type)
    custom_attributes = conversation.custom_attributes || {}
    missing = definitions.any? do |definition|
      key = definition.attribute_key
      value_present = custom_attributes.key?(key) || custom_attributes.key?(key.to_sym)
      value = custom_attributes.key?(key) ? custom_attributes[key] : custom_attributes[key.to_sym]
      next !value_present if definition.attribute_display_type == 'checkbox'

      value.nil? || value.to_s.strip.empty?
    end
    raise SkippedRecord, 'Required conversation attributes are missing' if missing
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
    return if accessible_links.count == communication_thread.communication_thread_conversations.count

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

  def flush_progress(processed_count, failed_count, skipped_count)
    return unless @bulk_action_run

    @bulk_action_run.advance!(
      processed_increment: processed_count,
      failed_increment: failed_count,
      skipped_increment: skipped_count
    )
  end

end
