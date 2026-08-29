class Crm::PipelinePolicy < Crm::BasePolicy
  def index?
    deal_view_access? || settings_view_access?
  end

  def show?
    deal_view_access? || settings_view_access?
  end

  def create?
    settings_manage_access?
  end

  def update?
    settings_manage_access?
  end

  def reorder_stages?
    update?
  end

  def destroy?
    settings_manage_access?
  end
end
