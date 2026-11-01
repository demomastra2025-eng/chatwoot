# frozen_string_literal: true

class Billing::OwnerTaskService
  def create_idempotent_task!(idempotency_key:, title:, description:, priority: 'high', due_on: Billing.today_almaty)
    workspace, owner_id = resolve_owner_workspace
    return nil unless workspace

    existing = Crm::Task.find_by(account_id: workspace.id, idempotency_key: idempotency_key)
    return existing if existing

    provision_task_catalogs!(workspace)
    status, task_type = resolve_status_and_type(workspace)
    return nil unless status && task_type

    task_attributes = {
      account_id: workspace.id, status_id: status.id, task_type_id: task_type.id,
      activity_type: task_type.code, assignee_id: owner_id, creator_id: owner_id,
      priority: priority, all_day: true, due_on: due_on,
      idempotency_key: idempotency_key, external_ref: idempotency_key,
      title: title.to_s.slice(0, 240), description: description
    }
    Crm::Task.create!(task_attributes)
  rescue ActiveRecord::RecordNotUnique
    Crm::Task.find_by(account_id: workspace&.id, idempotency_key: idempotency_key)
  end

  private

  def resolve_owner_workspace
    owner = User.find_by(id: OwnerFinance::AccessPolicy.owner_user_id)
    return [nil, nil] unless owner

    workspace = Account.find_by(id: OwnerFinance::AccessPolicy.workspace_account_id)
    return [nil, nil] unless workspace

    member_ids = workspace.account_users.pluck(:user_id)
    return [workspace, owner.id] if member_ids == [owner.id]

    Rails.logger.warn("[Billing::OwnerTaskService] Workspace ##{workspace.id} is not exclusive to owner ##{owner.id}")
    [nil, nil]
  end

  def provision_task_catalogs!(workspace)
    Crm::TaskCatalogs::Provisioner.new(account: workspace).perform
  end

  def resolve_status_and_type(workspace)
    status = Crm::TaskStatus.find_by(account_id: workspace.id, code: 'todo') ||
             Crm::TaskStatus.where(account_id: workspace.id, category: 'open').order(:position, :id).first
    task_type = Crm::TaskType.find_by(account_id: workspace.id, code: 'task') ||
                Crm::TaskType.where(account_id: workspace.id).order(:position, :id).first
    [status, task_type]
  end
end
