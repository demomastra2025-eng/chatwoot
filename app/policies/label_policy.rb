class LabelPolicy < ApplicationPolicy
  def index?
    runtime_access?
  end

  def update?
    administrator_access?
  end

  def show?
    administrator_access?
  end

  def create?
    administrator_access?
  end

  def destroy?
    administrator_access?
  end
end
