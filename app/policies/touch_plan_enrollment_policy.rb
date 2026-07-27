class TouchPlanEnrollmentPolicy < ApplicationPolicy
  def index?
    administrator_access? || permission_tokens.include?('outbound_view') || permission_tokens.include?('outbound_manage')
  end

  def cancel?
    administrator_access? || permission_tokens.include?('outbound_manage')
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      return scope.none if account.blank?
      return scope.where(account_id: account.id) if administrator_access? || outbound_access?

      scope.none
    end

    private

    def administrator_access?
      account_user&.administrator?
    end

    def outbound_access?
      permission_tokens.intersect?(%w[outbound_view outbound_manage])
    end

    def permission_tokens
      Array(account_user&.permissions)
    end
  end

  private

  def administrator_access?
    account_user&.administrator?
  end

  def permission_tokens
    Array(account_user&.permissions)
  end
end
