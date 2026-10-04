module Crm::Tasks::ExpandCompatibility
  private

  def provision_task_catalogs!
    Crm::TaskCatalogs::Provisioner.new(account: account).perform
  end

  def prepare_expand_compatibility!
    task.context_kind ||= task.effective_context_kind
    task.task_type ||= task.effective_task_type
    hydrate_legacy_outcome!
  end

  def hydrate_legacy_outcome!
    return if task.task_outcome_id.present? || task.outcome.blank? || task.task_type.blank?

    task.task_outcome = task.task_type.outcomes.find_by(code: task.outcome.to_s.strip.downcase)
  end
end
