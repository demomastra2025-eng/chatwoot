class Captain::AssistantPolicy < ApplicationPolicy
  def index?
    true
  end

  def show?
    true
  end

  def tools?
    @account_user.administrator?
  end

  def context_fields?
    update?
  end

  def tool_access?
    update?
  end

  def create?
    @account_user.administrator?
  end

  def update?
    @account_user.administrator?
  end

  def avatar?
    update?
  end

  def destroy?
    @account_user.administrator?
  end

  def playground?
    true
  end
end
