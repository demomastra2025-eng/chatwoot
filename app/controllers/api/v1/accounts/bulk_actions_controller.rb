class Api::V1::Accounts::BulkActionsController < Api::V1::Accounts::BaseController
  def create
    case normalized_type
    when 'Conversation', 'CommunicationThread'
      ensure_communication_threads_feature_enabled! if normalized_type == 'CommunicationThread'
      return if performed?

      bulk_action_run = create_conversation_bulk_action_run!
      enqueue_conversation_job(bulk_action_run)
      render json: { payload: bulk_action_run.as_progress_json }, status: :ok
    when 'Contact'
      check_authorization_for_contact_action
      enqueue_contact_job
      head :ok
    else
      render json: { success: false }, status: :unprocessable_content
    end
  end

  private

  def normalized_type
    params[:type].to_s.camelize
  end

  def enqueue_conversation_job(bulk_action_run)
    ::BulkActionsJob.perform_later(
      account: @current_account,
      user: current_user,
      params: conversation_params,
      bulk_action_run_id: bulk_action_run.id
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
    common = params.permit(:type, :action_name, ids: [], labels: [add: [], remove: []])
    base_params.merge(common)
  end

  def create_conversation_bulk_action_run!
    @current_account.bulk_action_runs.create!(
      user: current_user,
      resource_type: normalized_type,
      action_name: conversation_action_name,
      metadata: {
        selected_count: Array(params[:ids]).size
      }
    )
  end

  def conversation_action_name
    return params[:action_name].to_s if params[:action_name].present?
    return 'remove_labels' if params.dig(:labels, :remove).present?
    return 'add_labels' if params.dig(:labels, :add).present?

    fields = conversation_fields
    return 'update' if fields.keys.size > 1
    return 'update_status' if fields.key?(:status) || fields.key?('status')
    return 'assign_agent' if fields.key?(:assignee_id) || fields.key?('assignee_id')
    return 'assign_team' if fields.key?(:team_id) || fields.key?('team_id')

    'update'
  end

  def conversation_fields
    @conversation_fields ||= params.fetch(:fields, ActionController::Parameters.new)
                                   .permit(:status, :assignee_id, :team_id)
                                   .to_h
  end

  def ensure_communication_threads_feature_enabled!
    return if Current.account&.feature_enabled?('communication_threads')

    render json: { error: 'Communication threads feature is disabled' }, status: :forbidden
  end
end
