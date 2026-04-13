class CampaignPolicy < ApplicationPolicy
  def index?
    @account_user.administrator?
  end

  def update?
    @account_user.administrator?
  end

  def show?
    @account_user.administrator?
  end

  def analytics?
    show?
  end

  def preview?
    create?
  end

  def retry_failed?
    create?
  end

  def cancel?
    update?
  end

  def restart?
    create?
  end

  def resume?
    create?
  end

  def create?
    @account_user.administrator?
  end

  def destroy?
    @account_user.administrator?
  end
end
