class AccessRolePolicy < ApplicationPolicy
  def index?
    account_user&.administrator?
  end

  def create?
    index?
  end

  def update?
    index?
  end

  def destroy?
    index?
  end
end
