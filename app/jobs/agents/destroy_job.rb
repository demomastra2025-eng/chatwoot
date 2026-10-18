class Agents::DestroyJob < ApplicationJob
  queue_as :low

  def perform(account, user)
    user.with_lock do
      next if AccountUser.exists?(account: account, user: user)

      destroy_notification_setting(account, user)
      remove_user_from_teams(account, user)
      remove_user_from_inboxes(account, user)
      unassign_conversations(account, user)
      unassign_contacts(account, user)
    end
  end

  private

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

  def unassign_conversations(account, user)
    # rubocop:disable Rails/SkipsModelValidations
    user.assigned_conversations.where(account: account).in_batches.update_all(assignee_id: nil)
    # rubocop:enable Rails/SkipsModelValidations
  end

  def unassign_contacts(account, user)
    # rubocop:disable Rails/SkipsModelValidations
    account.contacts.where(owner_id: user.id).in_batches.update_all(owner_id: nil, updated_at: Time.current)
    # rubocop:enable Rails/SkipsModelValidations
  end
end
