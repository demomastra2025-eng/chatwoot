class Platform::Api::V1::AccountsController < PlatformController
  def index
    @resources = @platform_app.platform_app_permissibles
                              .where(permissible_type: 'Account')
                              .includes(:permissible)
                              .map(&:permissible)
  end

  def show; end

  # A new account gets the base plan first; the limits and features the platform app sends are applied after it,
  # so what the caller asked for wins over the plan.
  def create
    ActiveRecord::Base.transaction do
      @resource = Account.create!(account_params)
      Accounts::ApplyPlan.new(account: @resource, modules: [], keep_existing_limits: true).call
      update_resource_features
      @resource.save!
    end
    @platform_app.platform_app_permissibles.find_or_create_by(permissible: @resource)
  end

  def update
    @resource.assign_attributes(account_params)
    update_resource_features
    @resource.save!
  end

  def destroy
    DeleteObjectJob.perform_later(@resource)
    head :ok
  end

  private

  def set_resource
    @resource = Account.find(params[:id])
  end

  def account_params
    permitted_params.except(:features)
  end

  def update_resource_features
    return if permitted_params[:features].blank?

    permitted_params[:features].each do |key, value|
      value.present? ? @resource.enable_features(key) : @resource.disable_features(key)
    end
  end

  def permitted_params
    params.permit(:name, :locale, :domain, :support_email, :status, features: {}, limits: {}, custom_attributes: {})
  end
end
