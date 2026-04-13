class ReminderPolicy < ApplicationPolicy
  def index?
    outbound_view_access?
  end

  def show?
    scope.exists?(id: record.id)
  end

  def create?
    outbound_manage_access? || own_touch_access?
  end

  def update?
    outbound_manage_access? || own_touch_access?
  end

  def destroy?
    update?
  end

  def approve?
    update?
  end

  def cancel?
    update?
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      return scope.none if account.blank?
      return scope.where(account_id: account.id) if administrator_access? || outbound_view_access? || outbound_manage_access?

      scope.where(account_id: account.id, owner_id: user.id)
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

  def own_touch_access?
    record.respond_to?(:owner_id) ? record.owner_id == user.id : true
  end

  def permission_tokens
    Array(account_user&.permissions)
  end
end
