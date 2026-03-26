class Crm::TaskPolicy < Crm::BasePolicy
  def index?
    task_view_access?
  end

  def show?
    task_view_access?
  end

  def timeline?
    task_view_access?
  end

  def create?
    task_manage_access?
  end

  def update?
    task_manage_access?
  end

  def change_status?
    task_manage_access?
  end

  def archive?
    task_manage_access?
  end

  def unarchive?
    task_manage_access?
  end
end
