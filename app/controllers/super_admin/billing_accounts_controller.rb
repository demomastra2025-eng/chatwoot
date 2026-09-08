class SuperAdmin::BillingAccountsController < SuperAdmin::ApplicationController
  rescue_from ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound, ArgumentError,
              with: :handle_billing_error

  def show
    @active_plans = BillingPlan.active.includes(:prices).order(:name, :version)
    @current_subscription = requested_resource.current_subscription
    @audit_events = requested_resource.audit_events.includes(:super_admin).order(occurred_at: :desc).limit(50)
    super
  end

  def create
    resource = resource_class.new(resource_params)
    authorize_resource(resource)

    resource.class.transaction do
      resource.save!
      resource.audit_events.create!(super_admin: current_super_admin, action: 'billing_account_created',
                                    details: resource.billing_details)
    end
    redirect_to super_admin_billing_account_path(resource), notice: translate_with_resource('create.success')
  rescue ActiveRecord::RecordInvalid
    render :new, locals: { page: Administrate::Page::Form.new(dashboard, resource) }, status: :unprocessable_entity
  end

  def update
    resource = requested_resource
    authorize_resource(resource)
    manager.update_account!(resource_params)
    redirect_to super_admin_billing_account_path(resource), notice: translate_with_resource('update.success')
  rescue ActiveRecord::RecordInvalid
    render :edit, locals: { page: Administrate::Page::Form.new(dashboard, resource) }, status: :unprocessable_entity
  end

  def attach_workspace
    manager.attach_workspace!(params.require(:account_id))
    redirect_with_notice('Workspace attached')
  end

  def detach_workspace
    manager.detach_workspace!(params.require(:link_id))
    redirect_with_notice('Workspace detached')
  end

  def upsert_membership
    membership = params.require(:membership).permit(:user_id, :role)
    manager.upsert_membership!(**membership.to_h.symbolize_keys)
    redirect_with_notice('Billing membership saved')
  end

  def deactivate_membership
    manager.deactivate_membership!(params.require(:membership_id))
    redirect_with_notice('Billing membership deactivated')
  end

  def assign_subscription
    subscription = params.require(:subscription).permit(
      :plan_id, :price_id, :status, :current_period_starts_at, :current_period_ends_at
    )
    manager.assign_subscription!(
      plan_id: subscription[:plan_id],
      price_id: subscription[:price_id],
      status: subscription[:status],
      period_starts_at: subscription[:current_period_starts_at],
      period_ends_at: subscription[:current_period_ends_at]
    )
    redirect_with_notice('Subscription saved')
  end

  def update_allocation
    allocation = params.require(:allocation).permit(:account_id, :agents, :storage_gb)
    manager.update_allocation!(**allocation.to_h.symbolize_keys)
    redirect_with_notice('Workspace allocation saved')
  end

  private

  def manager
    @manager ||= Billing::Admin::AccountManager.new(
      billing_account: requested_resource,
      actor: current_super_admin
    )
  end

  def redirect_with_notice(message)
    redirect_to super_admin_billing_account_path(requested_resource), notice: message
  end

  def handle_billing_error(error)
    billing_account = resource_class.find_by(id: params[:id])
    fallback = billing_account ? super_admin_billing_account_path(billing_account) : super_admin_billing_accounts_path
    redirect_to fallback, alert: error.message
  end
end
