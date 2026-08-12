class HookPolicy < ApplicationPolicy
  def create?
    @account_user.administrator?
  end

  def update?
    @account_user.administrator?
  end

  def process_event?
    @account_user.administrator?
  end

  def run_sync?
    @account_user.administrator?
  end

  def sync_status?
    @account_user.administrator?
  end

  def sync_conflict?
    @account_user.administrator?
  end

  def resolve_sync_conflict?
    @account_user.administrator?
  end

  def import_catalog?
    @account_user.administrator?
  end

  def destroy?
    @account_user.administrator?
  end
end
