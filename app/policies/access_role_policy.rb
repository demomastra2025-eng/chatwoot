class AccessRolePolicy < ApplicationPolicy
  def index?
    account_user&.administrator?
  end
end
