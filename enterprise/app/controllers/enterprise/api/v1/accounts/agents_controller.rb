module Enterprise::Api::V1::Accounts::AgentsController
  def create
    ActiveRecord::Base.transaction do
      super
      associate_agent_with_custom_role if custom_role_parameter?
    end
  end

  def update
    ActiveRecord::Base.transaction do
      super
      associate_agent_with_custom_role if custom_role_parameter?
    end
  end

  private

  def associate_agent_with_custom_role
    custom_role = Current.account.custom_roles.find(params[:custom_role_id]) if params[:custom_role_id].present?
    account_user = @agent.current_account_user
    access_role = materialized_access_role(custom_role) unless account_user.administrator?
    account_user.update!(custom_role: custom_role, access_role: access_role)
  end

  def custom_role_parameter?
    params.key?(:custom_role_id)
  end

  def materialized_access_role(custom_role)
    return unless custom_role

    analysis = AccessControl::LegacyCustomRoleMapper.analyze(custom_role)
    return unless analysis.mappable?

    AccessControl::LegacyCustomRoleMapper.call(custom_role: custom_role)
  end
end
