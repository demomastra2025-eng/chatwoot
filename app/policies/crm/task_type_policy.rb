class Crm::TaskTypePolicy < Crm::BasePolicy
  def index?
    task_view_access? || settings_view_access?
  end

  def show?
    index?
  end

  def create?
    settings_manage_access?
  end

  def update?
    settings_manage_access?
  end

  def destroy?
    settings_manage_access?
  end
end
