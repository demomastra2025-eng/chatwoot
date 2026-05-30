class CustomAttributeDefinitionPolicy < ApplicationPolicy
  def index?
    runtime_access?
  end

  def show?
    runtime_access?
  end

  def create?
    administrator_access?
  end

  def update?
    administrator_access?
  end

  def destroy?
    administrator_access?
  end
end
