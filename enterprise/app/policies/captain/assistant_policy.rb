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

  # The compiled prompt is for the platform team only, never for a clinic (Captain::PromptInspectorAccess).
  def prompt_preview?
    Captain::PromptInspectorAccess.allowed?(user: user, impersonation: user_context[:super_admin_impersonation])
  end

  def voice_preview?
    update?
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
