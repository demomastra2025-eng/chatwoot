class Crm::BasePolicy < ApplicationPolicy
  class Scope < ApplicationPolicy::Scope
    def resolve
      return scope.none if account.blank?

      scope.where(account_id: account.id)
    end
  end

  private

  def settings_view_access?
    administrator_access? || has_permission?('crm_settings_view', 'crm_settings_manage')
  end

  def settings_manage_access?
    administrator_access? || has_permission?('crm_settings_manage')
  end

  def deal_view_access?
    administrator_access? || plain_agent_access? || has_permission?('crm_deal_view', 'crm_deal_manage')
  end

  def deal_manage_access?
    administrator_access? || plain_agent_access? || has_permission?('crm_deal_manage')
  end

  def task_view_access?
    administrator_access? || plain_agent_access? || has_permission?('crm_task_view', 'crm_task_manage')
  end

  def task_manage_access?
    administrator_access? || plain_agent_access? || has_permission?('crm_task_manage')
  end

  def crm_record_view_access?
    deal_view_access? || task_view_access?
  end
end
