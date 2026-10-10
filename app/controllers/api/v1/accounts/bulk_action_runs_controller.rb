class Api::V1::Accounts::BulkActionRunsController < Api::V1::Accounts::BaseController
  rescue_from Conversations::DeletionService::InvalidRequest do
    render json: { error: 'conversation_deletion_invalid' }, status: :unprocessable_content
  end

  def index
    run = Conversations::DeletionService.new(account: @current_account, user: current_user).lookup(params[:request_key])
    render json: { payload: Conversations::DeletionService.progress(run) }
  end

  def show
    bulk_action_run = @current_account.bulk_action_runs.find_by!(id: Conversations::DeletionService.identity(params[:id]), user_id: current_user.id)
    progress = if bulk_action_run.resource_type == 'Conversation' && bulk_action_run.action_name == 'delete' &&
                  bulk_action_run.metadata['operation_kind'] == Conversations::DeletionService::KIND
                 Conversations::DeletionService.progress(bulk_action_run)
               else
                 bulk_action_run.as_progress_json
               end
    render json: { payload: progress }
  end
end
