class Agents::DestroyJob < ApplicationJob
  queue_as :low

  def perform(account, user, transfer_to_user_id = nil)
    user.with_lock do
      next if AccountUser.exists?(account: account, user: user)

      target_user_id = resolve_target_user_id(account, user, transfer_to_user_id)

      destroy_notification_setting(account, user)
      remove_user_from_teams(account, user)
      remove_user_from_inboxes(account, user)
      reassign_or_unassign_conversations(account, user, target_user_id)
      reassign_or_unassign_owned_records(account, user, target_user_id)
    end
  end

  private

  def resolve_target_user_id(account, user, transfer_to_user_id)
    return nil if transfer_to_user_id.blank?

    candidate_id = transfer_to_user_id.to_i
    return nil if candidate_id <= 0 || candidate_id == user.id
    return nil unless AccountUser.exists?(account_id: account.id, user_id: candidate_id)

    candidate_id
  end

  def remove_user_from_inboxes(account, user)
    inboxes = account.inboxes.all
    inbox_members = user.inbox_members.where(inbox_id: inboxes.pluck(:id))
    inbox_members.destroy_all
  end

  def remove_user_from_teams(account, user)
    teams = account.teams.all
    team_members = user.team_members.where(team_id: teams.pluck(:id))
    team_members.destroy_all
  end

  def destroy_notification_setting(account, user)
    setting = user.notification_settings.find_by(account_id: account.id)
    setting&.destroy!
  end

  def reassign_or_unassign_conversations(account, user, target_user_id)
    # rubocop:disable Rails/SkipsModelValidations
    user.assigned_conversations.where(account: account).in_batches.update_all(assignee_id: target_user_id)
    # rubocop:enable Rails/SkipsModelValidations
  end

  def reassign_or_unassign_owned_records(account, user, target_user_id)
    now = Time.current
    reassign_or_unassign_crm_records(account, user, target_user_id, now)
    reassign_or_unassign_operational_records(account, user, target_user_id, now)
    reassign_or_clear_client_ownerships(account, user, target_user_id, now)
    resolve_foreign_contact_owner_conflicts(account, user, now)
  end

  def reassign_or_unassign_crm_records(account, user, target_user_id, now)
    # rubocop:disable Rails/SkipsModelValidations
    account.contacts.where(owner_id: user.id).in_batches.update_all(owner_id: target_user_id, updated_at: now)
    Crm::Deal.where(account_id: account.id, owner_id: user.id).in_batches.update_all(owner_id: target_user_id, updated_at: now)
    Crm::Task.where(account_id: account.id, assignee_id: user.id).in_batches.update_all(assignee_id: target_user_id, updated_at: now)
    # rubocop:enable Rails/SkipsModelValidations
  end

  def reassign_or_unassign_operational_records(account, user, target_user_id, now)
    # rubocop:disable Rails/SkipsModelValidations
    Scheduling::Appointment.where(account_id: account.id, owner_id: user.id).in_batches.update_all(owner_id: target_user_id, updated_at: now)
    Reminder.where(account_id: account.id, owner_id: user.id).in_batches.update_all(owner_id: target_user_id, updated_at: now)
    CommunicationThread.where(account_id: account.id, assignee_id: user.id).in_batches.update_all(assignee_id: target_user_id, updated_at: now)
    # rubocop:enable Rails/SkipsModelValidations
  end

  def reassign_or_clear_client_ownerships(account, user, target_user_id, now)
    scope = AssignmentClientOwnership.where(account_id: account.id, user_id: user.id)
    if target_user_id.present?
      # rubocop:disable Rails/SkipsModelValidations
      scope.in_batches.update_all(user_id: target_user_id, last_assigned_at: now, updated_at: now)
      # rubocop:enable Rails/SkipsModelValidations
    else
      scope.delete_all
    end
  end

  def resolve_foreign_contact_owner_conflicts(account, user, now)
    # rubocop:disable Rails/SkipsModelValidations
    ::Integrations::Medelement::SyncConflict
      .where(account_id: account.id, conflict_type: 'foreign_contact_owner', status: 'open')
      .where("details ->> 'owner_id' = ?", user.id.to_s)
      .update_all(status: 'resolved', resolved_at: now, updated_at: now)
    # rubocop:enable Rails/SkipsModelValidations
  end
end
