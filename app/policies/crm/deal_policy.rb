class Crm::DealPolicy < Crm::BasePolicy
  def index?
    deal_view_access?
  end

  def show?
    deal_view_access?
  end

  def timeline?
    deal_view_access?
  end

  def create?
    deal_manage_access?
  end

  def update?
    deal_manage_access?
  end

  def transition_stage?
    deal_manage_access?
  end

  def archive?
    deal_manage_access?
  end

  def unarchive?
    deal_manage_access?
  end
end
