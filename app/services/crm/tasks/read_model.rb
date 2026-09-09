class Crm::Tasks::ReadModel
  attr_reader :task, :task_outcome, :task_type

  def initialize(task:, catalog_snapshot: nil)
    @task = task
    @task_type = task.task_type
    @task_outcome = task.task_outcome
    return if task_type.present? && (raw_outcome.blank? || task_outcome.present?)

    snapshot = catalog_snapshot || Crm::Tasks::CatalogSnapshot.new(account: task.account)
    @task_type = snapshot.task_type_for(task)
    @task_outcome = snapshot.task_outcome_for(task, task_type: @task_type)
  end

  def context_kind
    task.effective_context_kind
  end

  def outcome
    raw_outcome || task_outcome&.code
  end

  private

  def raw_outcome
    task.attributes['outcome'].presence
  end
end
