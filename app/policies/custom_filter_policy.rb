class CustomFilterPolicy < ApplicationPolicy
  def create?
    runtime_access?
  end

  def show?
    runtime_access?
  end

  def index?
    runtime_access?
  end

  def update?
    runtime_access?
  end

  def destroy?
    runtime_access?
  end
end
