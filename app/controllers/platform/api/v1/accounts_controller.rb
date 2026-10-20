# Accounts of the partner. The features a partner switches go through the same check as the super admin screens
# (SuperAdmin::FeatureChangeGuard): a function that no plan ever enables, one that must stay on and a platform-internal
# one are refused, and a request with such a function changes nothing. Every create, update and delete leaves an entry
# in the audit log with the partner as the actor.
#
# The limits a super admin chose for an account (a number of its own or «без ограничений», see Accounts::LimitSettings) are not
# the partner's to change: the numbers a request sends for them are ignored, and the list of them survives a request that replaces
# `custom_attributes`. The numbers the partner sends for the other limits are applied on top of what the account has (the limits
# the request does not name stay), and they are the partner's numbers for the moment: a plan applied later writes its own number
# over a limit that follows the plan.
class Platform::Api::V1::AccountsController < PlatformController
  # The settings of an account whose new values are written to the audit log
  AUDITED_ACCOUNT_FIELDS = %w[name locale status limits custom_attributes].freeze

  def index
    @resources = @platform_app.platform_app_permissibles
                              .where(permissible_type: 'Account')
                              .includes(:permissible)
                              .map(&:permissible)
  end

  def show; end

  # A new account gets the base plan first; the limits and features the platform app sends are applied after it,
  # so what the caller asked for wins over the plan (within what the guard allows).
  def create
    violations = []
    ActiveRecord::Base.transaction do
      @resource = Account.create!(account_params.except(:limits))
      Accounts::ApplyPlan.new(account: @resource, modules: []).call
      violations = feature_violations(@resource)
      raise ActiveRecord::Rollback if violations.any?

      assign_partner_limits(@resource, account_params[:limits])
      update_resource_features
      @resource.save!
    end
    return render_feature_refusal(violations) if violations.any?

    @platform_app.platform_app_permissibles.find_or_create_by(permissible: @resource)
    audit_account(@resource, 'partner_create_account', created_changes(@resource))
  end

  def update
    violations = feature_violations(@resource)
    return render_feature_refusal(violations) if violations.any?

    assign_account_attributes(@resource)
    changes = account_changes(@resource).merge(update_resource_features)
    @resource.save!
    audit_account(@resource, 'partner_update_account', changes) if changes.any?
  end

  def destroy
    snapshot = { 'name' => @resource.name }
    DeleteObjectJob.perform_later(@resource)
    audit_account(@resource, 'partner_destroy_account', snapshot)
    head :ok
  end

  private

  def set_resource
    @resource = Account.find(params[:id])
  end

  def account_params
    permitted_params.except(:features)
  end

  # The settings of the request on the account (nothing is saved): `custom_attributes` replaces the old ones as a whole, but cannot
  # take the list of the limits a super admin chose, nor write it; the limits go through #assign_partner_limits.
  def assign_account_attributes(account)
    chosen = account.custom_attributes.to_h.slice(Accounts::LimitSettings::KEY)
    attributes = account_params
    numbers = attributes.delete(:limits)
    account.assign_attributes(attributes)
    if attributes.key?(:custom_attributes)
      account.custom_attributes = account.custom_attributes.to_h.except(Accounts::LimitSettings::KEY).merge(chosen)
    end
    assign_partner_limits(account, numbers)
  end

  # The numbers of the request go on top of the limits of the account, except for the limits a super admin chose
  def assign_partner_limits(account, numbers)
    return if numbers.blank?

    chosen = Accounts::LimitSettings.marks_in(account.custom_attributes).keys
    account.limits = account.limits.to_h.merge(numbers.to_h.stringify_keys.except(*chosen))
  end

  # { 'flag' => true | false } as the partner sent it (the strings 'false' and '0' are off)
  def requested_features
    boolean = ActiveModel::Type::Boolean.new
    permitted_params[:features].to_h.to_h do |key, value|
      [key.to_s.delete_prefix('feature_'), boolean.cast(value) ? true : false]
    end
  end

  # What the guard refuses in the features of the request, for this account in its present state
  def feature_violations(account)
    return [] if permitted_params[:features].blank?

    SuperAdmin::FeatureChangeGuard.new(account).violations(requested_features)
  end

  def render_feature_refusal(violations)
    render json: {
      error: 'These features cannot be changed through the Platform API. Nothing was saved.',
      violations: violations.map { |violation| { feature: violation.flag, reason: violation.reason } }
    }, status: :unprocessable_content
  end

  # Applies the features of the request; returns what changed, for the audit log:
  # { 'features' => { 'crm' => { 'from' => false, 'to' => true } } }
  def update_resource_features
    return {} if permitted_params[:features].blank?

    changed = SuperAdmin::FeatureChangeGuard.new(@resource).changes(requested_features)
    changed.each { |key, value| value ? @resource.enable_features(key) : @resource.disable_features(key) }
    return {} if changed.empty?

    { 'features' => changed.transform_values { |wanted| { 'from' => !wanted, 'to' => wanted } } }
  end

  # The settings the request changed, as the audit log keeps them: { 'name' => ['old', 'new'] }
  def account_changes(account)
    account.changes.slice(*AUDITED_ACCOUNT_FIELDS)
  end

  def created_changes(account)
    account.attributes.slice(*AUDITED_ACCOUNT_FIELDS).compact_blank.merge('features' => account.enabled_features.keys)
  end

  def permitted_params
    params.permit(:name, :locale, :status, features: {}, limits: {}, custom_attributes: {})
  end
end
