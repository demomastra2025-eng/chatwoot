class ReminderGroupPolicy < ApplicationPolicy
  def index?
    outbound_view_access?
  end

  def show?
    scope.exists?(id: record.id)
  end

  def create?
    outbound_manage_access?
  end

  def update?
    outbound_manage_access?
  end

  def apply?
    outbound_manage_access?
  end

  def archive?
    outbound_manage_access?
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      return scope.none if account.blank?
      return scope.where(account_id: account.id) if administrator_access? || outbound_view_access? || outbound_manage_access?

      scope.none
    end

    private

    def administrator_access?
      account_user&.administrator?
    end

    def outbound_view_access?
      permission_tokens.include?('outbound_view')
    end

    def outbound_manage_access?
      permission_tokens.include?('outbound_manage')
    end

    def permission_tokens
      Array(account_user&.permissions)
    end
  end

  private

  def administrator_access?
    account_user&.administrator?
  end

  def outbound_view_access?
    administrator_access? || permission_tokens.include?('outbound_view') || outbound_manage_access?
  end

  def outbound_manage_access?
    administrator_access? || permission_tokens.include?('outbound_manage')
  end

  def permission_tokens
    Array(account_user&.permissions)
  end
end
