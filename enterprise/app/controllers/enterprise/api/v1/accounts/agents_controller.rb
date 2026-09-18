module Enterprise::Api::V1::Accounts::AgentsController
  def create
    ensure_assignment_parameters_compatible!
    ActiveRecord::Base.transaction do
      super
      assign_agent_role
    end
  rescue AccessControl::AccessRoleAssigner::Error => e
    render_assignment_error(e)
  end

  def update
    ensure_assignment_parameters_compatible!
    ActiveRecord::Base.transaction do
      super
      assign_agent_role
    end
  rescue AccessControl::AccessRoleAssigner::Error => e
    render_assignment_error(e)
  end

  private

  def assign_agent_role
    return assign_canonical_access_role if access_role_parameter?
    return if canonical_assignments_enabled? && !legacy_assignment_change?

    associate_agent_with_custom_role if custom_role_parameter?
  end

  def assign_canonical_access_role
    expected_access_role_id = if action_name == 'update'
                                params[:previous_access_role_id]
                              else
                                AccessControl::AccessRoleAssigner::EXPECTED_ROLE_UNSET
                              end
    AccessControl::AccessRoleAssigner.assign(
      account: Current.account,
      account_user: @agent.current_account_user,
      access_role_id: params[:access_role_id],
      expected_access_role_id: expected_access_role_id
    )
    @agent.current_account_user.reload
  end

  def associate_agent_with_custom_role
    custom_role = Current.account.custom_roles.find(params[:custom_role_id]) if params[:custom_role_id].present?
    account_user = @agent.current_account_user
    access_role = materialized_access_role(custom_role) unless account_user.administrator?
    account_user.update!(custom_role: custom_role, access_role: access_role)
  end

  def custom_role_parameter?
    params.key?(:custom_role_id)
  end

  def access_role_parameter?
    params.key?(:access_role_id)
  end

  def ensure_assignment_parameters_compatible!
    if access_role_parameter?
      ensure_canonical_assignment_parameters!
    elsif canonical_assignments_enabled? && legacy_assignment_change?
      raise_assignment_error(
        'LEGACY_ROLE_ASSIGNMENTS_DISABLED',
        'Legacy role assignments are disabled while normalized assignments are enabled'
      )
    end
  end

  def ensure_canonical_assignment_parameters!
    if custom_role_parameter? || params.key?(:role)
      raise_assignment_error('AMBIGUOUS_ROLE_ASSIGNMENT', 'Use either access_role_id or legacy role fields, not both')
    end
    return unless action_name == 'update' && !params.key?(:previous_access_role_id)

    raise_assignment_error('PREVIOUS_ACCESS_ROLE_ID_REQUIRED', 'previous_access_role_id is required for updates')
  end

  def legacy_assignment_change?
    return params.key?(:role) || custom_role_parameter? if action_name == 'create'

    account_user = @agent.current_account_user
    role_changed = params.key?(:role) && params[:role].to_s != account_user.role
    custom_role_changed = custom_role_parameter? && normalized_custom_role_id != account_user.custom_role_id
    role_changed || custom_role_changed
  end

  def normalized_custom_role_id
    params[:custom_role_id].presence&.to_i
  end

  def canonical_assignments_enabled?
    AccessControl::AccessRoleAssigner.assignments_enabled_for?(account: Current.account)
  end

  def raise_assignment_error(code, message)
    raise AccessControl::AccessRoleAssigner::Error.new(code, message, status: :conflict)
  end

  def render_assignment_error(error)
    render json: { error: error.message, code: error.code }, status: error.status
  end

  def materialized_access_role(custom_role)
    return unless custom_role

    analysis = AccessControl::LegacyCustomRoleMapper.analyze(custom_role)
    return unless analysis.mappable?

    AccessControl::LegacyCustomRoleMapper.call(custom_role: custom_role)
  end
end
