class Crm::PipelinePolicy < Crm::BasePolicy
  def index?
    settings_view_access?
  end

  def show?
    settings_view_access?
  end

  def create?
    settings_manage_access?
  end

  def update?
    settings_manage_access?
  end
end
