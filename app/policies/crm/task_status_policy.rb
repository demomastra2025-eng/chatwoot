class Crm::TaskStatusPolicy < Crm::BasePolicy
  def index?
    task_view_access? || settings_view_access?
  end

  def show?
    task_view_access? || settings_view_access?
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
