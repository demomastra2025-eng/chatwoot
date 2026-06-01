class Captain::McpServerPolicy < ApplicationPolicy
  def index?
    true
  end

  def show?
    @account_user.administrator?
  end

  def create?
    @account_user.administrator?
  end

  def update?
    @account_user.administrator?
  end

  def test?
    @account_user.administrator?
  end

  def surface?
    @account_user.administrator?
  end

  def read_resource?
    @account_user.administrator?
  end

  def fetch_resource_template?
    @account_user.administrator?
  end

  def fetch_prompt?
    @account_user.administrator?
  end

  def task_get?
    @account_user.administrator?
  end

  def task_result?
    @account_user.administrator?
  end

  def task_cancel?
    @account_user.administrator?
  end

  def oauth_start?
    @account_user.administrator?
  end

  def oauth_disconnect?
    @account_user.administrator?
  end

  def destroy?
    @account_user.administrator?
  end
end
