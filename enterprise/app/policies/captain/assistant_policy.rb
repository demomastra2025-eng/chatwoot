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

  def prompt_preview?
    true
  end

  def preview?
    update?
  end

  def resync?
    update?
  end

  def refresh_changed_only?
    update?
  end

  def retry_failed?
    update?
  end

  def source_text?
    show?
  end
end
