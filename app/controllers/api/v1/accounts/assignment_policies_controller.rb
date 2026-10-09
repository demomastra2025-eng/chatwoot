class Api::V1::Accounts::AssignmentPoliciesController < Api::V1::Accounts::BaseController
  before_action :fetch_assignment_policy, only: [:show, :update, :destroy]
  before_action :check_authorization

  def index
    @assignment_policies = Current.account.assignment_policies
  end

  def show; end

  def create
    @assignment_policy = Current.account.assignment_policies.create!(assignment_policy_params)
  end

  def update
    account = @assignment_policy.account
    account.with_lock('FOR NO KEY UPDATE') do
      if selected_workspace_policy?(account) && disabling_policy?
        return render json: { error_code: 'selected_workspace_assignment_policy' }, status: :conflict
      end

      @assignment_policy.update!(assignment_policy_params)
    end
  end

  def destroy
    account = @assignment_policy.account
    account.with_lock('FOR NO KEY UPDATE') do
      if selected_workspace_policy?(account)
        return render json: { error_code: 'selected_workspace_assignment_policy' }, status: :conflict
      end

      @assignment_policy.destroy!
      head :ok
    end
  end

  private

  def fetch_assignment_policy
    @assignment_policy = Current.account.assignment_policies.find(params[:id])
  end

  def assignment_policy_params
    params.require(:assignment_policy).permit(
      :name, :description, :assignment_order, :conversation_priority,
      :fair_distribution_limit, :fair_distribution_window, :enabled,
      :assignment_delay_minutes, :max_open_conversations,
      :assign_pending_conversations, :assign_online_only,
      :monthly_new_client_quota, :sticky_owner_enabled,
      :sticky_owner_duration_days,
      exclusion_rules: [:exclude_older_than_minutes, { excluded_labels: [] }]
    )
  end

  def selected_workspace_policy?(account)
    account.conversation_assignment_policy_id.to_s == @assignment_policy.id.to_s
  end

  def disabling_policy?
    assignment_policy_params.key?(:enabled) &&
      ActiveModel::Type::Boolean.new.cast(assignment_policy_params[:enabled]) == false
  end
end
