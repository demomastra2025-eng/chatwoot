class Api::V1::Accounts::BulkActionRunsController < Api::V1::Accounts::BaseController
  def show
    bulk_action_run = @current_account.bulk_action_runs.find_by!(id: params[:id], user_id: current_user.id)
    render json: { payload: bulk_action_run.as_progress_json }
  end
end
