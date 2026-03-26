class Crm::BasePolicy < ApplicationPolicy
  class Scope < ApplicationPolicy::Scope
    def resolve
      return scope.none if account.blank?

      scope.where(account_id: account.id)
    end
  end

  private

  def administrator_access?
    permission_tokens.include?('administrator')
  end

  def plain_agent_access?
    permission_tokens.include?('agent')
  end

  def settings_view_access?
    administrator_access? || permission_tokens.include?('crm_settings_view') || permission_tokens.include?('crm_settings_manage')
  end

  def settings_manage_access?
    administrator_access? || permission_tokens.include?('crm_settings_manage')
  end

  def deal_view_access?
    administrator_access? || permission_tokens.include?('crm_deal_view') || permission_tokens.include?('crm_deal_manage')
  end

  def deal_manage_access?
    administrator_access? || permission_tokens.include?('crm_deal_manage')
  end

  def task_view_access?
    administrator_access? || permission_tokens.include?('crm_task_view') || permission_tokens.include?('crm_task_manage')
  end

  def task_manage_access?
    administrator_access? || permission_tokens.include?('crm_task_manage')
  end

  def permission_tokens
    Array(account_user&.permissions)
  end
end
