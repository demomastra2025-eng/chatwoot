class Api::V1::Accounts::BulkActionsController < Api::V1::Accounts::BaseController
  def create
    case normalized_type
    when 'Conversation', 'CommunicationThread'
      ensure_communication_threads_feature_enabled! if normalized_type == 'CommunicationThread'
      return if performed?

      selection = selected_snapshot
      bulk_action_run = create_conversation_bulk_action_run!(selection: selection)
      enqueue_conversation_job(bulk_action_run, selection: selection)
      render json: { payload: bulk_action_run.as_progress_json }, status: :ok
    when 'Contact'
      check_authorization_for_contact_action
      enqueue_contact_job
      head :ok
    else
      render json: { success: false }, status: :unprocessable_content
    end
  rescue BulkActions::SelectionSnapshot::InvalidSelection
    render json: { error: { code: 'selection_invalid' } }, status: :unprocessable_content
  end

  def selection
    ensure_communication_threads_feature_enabled! if normalized_type == 'CommunicationThread'
    return if performed?

    render json: { payload: capture_selection.to_h }, status: :ok
  rescue BulkActions::SelectionSnapshot::TooManyRecords => e
    render json: { error: { code: 'selection_limit_exceeded', limit: e.limit } }, status: :unprocessable_content
  rescue BulkActions::SelectionSnapshot::EmptySelection
    render json: { error: { code: 'selection_empty' } }, status: :unprocessable_content
  rescue BulkActions::SelectionSnapshot::InvalidFilters,
         ActionController::ParameterMissing,
         CommunicationThreadFinder::InvalidParameter,
         CustomExceptions::CustomFilter::InvalidAttribute,
         CustomExceptions::CustomFilter::InvalidOperator,
         CustomExceptions::CustomFilter::InvalidQueryOperator,
         CustomExceptions::CustomFilter::InvalidValue,
         ActiveRecord::RecordNotFound,
         ArgumentError
    render json: { error: { code: 'selection_filters_invalid' } }, status: :unprocessable_content
  rescue BulkActions::SelectionSnapshot::InvalidSelection
    render json: { error: { code: 'selection_invalid' } }, status: :unprocessable_content
  end

  private

  def capture_selection
    BulkActions::SelectionSnapshot.new(
      account: @current_account,
      user: current_user,
      resource_type: normalized_type,
      filters: selection_filters
    ).perform
  end

  def normalized_type
    params[:type].to_s.camelize
  end

  def enqueue_conversation_job(bulk_action_run, selection: nil)
    action_params = conversation_params
    if selection
      action_params = action_params.except(:selection_token, :excluded_ids).merge(
        ids: selection.ids,
        record_ids: selection.record_ids
      )
    end

    ::BulkActionsJob.perform_later(
      account: @current_account,
      user: current_user,
      params: action_params,
      bulk_action_run_id: bulk_action_run.id,
      selection_count: selection&.count
    )
  end

  def enqueue_contact_job
    Contacts::BulkActionJob.perform_later(
      @current_account.id,
      current_user.id,
      contact_params
    )
  end

  def delete_contact_action?
    params[:action_name] == 'delete'
  end

  def check_authorization_for_contact_action
    authorize(Contact, :destroy?) if delete_contact_action?
  end

  def conversation_params
    # TODO: Align conversation payloads with the `{ action_name, action_attributes }`
    # and then remove this method in favor of a common params method.
    base = params.permit(:snoozed_until)
    base[:fields] = conversation_fields if conversation_fields.present?
    append_common_bulk_attributes(base)
  end

  def contact_params
    # TODO: remove this method in favor of a common params method.
    # once legacy conversation payloads are migrated.
    append_common_bulk_attributes({})
  end

  def append_common_bulk_attributes(base_params)
    # NOTE: Conversation payloads historically diverged per action. Going forward we
    # want all objects to share a common contract: `{ action_name, action_attributes }`
    common = params.permit(:type, :action_name, :selection_token, ids: [], excluded_ids: [], labels: [add: [], remove: []])
    base_params.merge(common)
  end

  def create_conversation_bulk_action_run!(selection: nil)
    @current_account.bulk_action_runs.create!(
      user: current_user,
      resource_type: normalized_type,
      action_name: conversation_action_name,
      metadata: {
        selected_count: selection&.count || Array(params[:ids]).size,
        selection_mode: ('filtered_snapshot' if selection)
      }
    )
  end

  def conversation_action_name
    return params[:action_name].to_s if params[:action_name].present?
    return 'remove_labels' if params.dig(:labels, :remove).present?
    return 'add_labels' if params.dig(:labels, :add).present?

    field_keys = conversation_fields.keys.map(&:to_s) - ['status_reason']
    return 'update' if field_keys.size > 1

    { 'status' => 'update_status', 'assignee_id' => 'assign_agent', 'team_id' => 'assign_team' }
      .fetch(field_keys.first, 'update')
  end

  def conversation_fields
    @conversation_fields ||= params.fetch(:fields, ActionController::Parameters.new)
                                   .permit(:status, :status_reason, :assignee_id, :team_id)
                                   .to_h
  end

  def selection_filters
    filters = params[:filters]
    filters.respond_to?(:to_unsafe_h) ? filters.to_unsafe_h : filters
  end

  def selected_snapshot
    token = params[:selection_token]
    return if token.blank?

    validate_snapshot_payload!

    claims = BulkActions::SelectionSnapshot.verify!(
      token,
      account: @current_account,
      user: current_user,
      resource_type: normalized_type
    )
    apply_snapshot_exclusions(claims)
  end

  def validate_snapshot_payload!
    conflicting_keys = %i[ids filters count selection_count record_ids]
    return unless conflicting_keys.any? { |key| params.key?(key) }

    raise BulkActions::SelectionSnapshot::InvalidSelection
  end

  def apply_snapshot_exclusions(claims)
    excluded_ids = Array(params[:excluded_ids]).map { |id| Integer(id) }
    validate_excluded_ids!(claims, excluded_ids)

    ids = claims.ids - excluded_ids
    raise BulkActions::SelectionSnapshot::InvalidSelection if ids.empty?

    record_ids_by_id = claims.ids.zip(claims.record_ids).to_h

    BulkActions::SelectionSnapshot::Claims.new(
      ids: ids,
      record_ids: ids.map { |id| record_ids_by_id.fetch(id) },
      count: ids.size,
      resource_type: claims.resource_type
    )
  rescue ArgumentError, TypeError
    raise BulkActions::SelectionSnapshot::InvalidSelection
  end

  def validate_excluded_ids!(claims, excluded_ids)
    raise BulkActions::SelectionSnapshot::InvalidSelection if excluded_ids.size > claims.count
    raise BulkActions::SelectionSnapshot::InvalidSelection unless excluded_ids.uniq == excluded_ids
    raise BulkActions::SelectionSnapshot::InvalidSelection unless (excluded_ids - claims.ids).empty?
  end

  def ensure_communication_threads_feature_enabled!
    return if Current.account&.feature_enabled?('communication_threads')

    render json: { error: 'Communication threads feature is disabled' }, status: :forbidden
  end
end
