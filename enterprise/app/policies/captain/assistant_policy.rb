class Captain::AssistantPolicy < ApplicationPolicy
  def index?
    true
  end

  def show?
    true
  end

  def tools?
    manage?
  end

  def context_fields?
    update?
  end

  def create?
    manage?
  end

  def update?
    manage?
  end

  def avatar?
    update?
  end

  def destroy?
    manage?
  end

  def playground?
    true
  end

  def prompt_preview?
    true
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

  private

  def manage?
    administrator_access? || has_permission?('captain_manage')
  end
end
