# frozen_string_literal: true

class Captain::Tools::Copilot::RemoveInboxMembersService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'remove_inbox_members'
  end

  description 'Remove one or more account users from an inbox membership list'
  param :inbox_id, type: :number, desc: 'Account inbox ID', required: true
  param :user_ids, type: :string, desc: 'Comma-separated account user IDs to remove from inbox members', required: true

  def execute(inbox_id:, user_ids:)
    inbox = account.inboxes.active.find(inbox_id)
    users = account_users!(user_ids)
    ids_to_remove = users.map(&:id) & inbox.members.pluck(:id)
    inbox.remove_members(ids_to_remove) if ids_to_remove.any?

    formatted_payload(
      action: 'remove_inbox_members',
      inbox: inbox_payload(inbox),
      removed_user_ids: ids_to_remove,
      members: member_payloads(inbox.reload)
    )
  rescue StandardError => e
    tool_failure(e)
  end

  def active?
    account_administrator?
  end

  private

  def account_users!(value)
    ids = parse_id_list(value, field_name: 'user_ids')
    raise ArgumentError, 'user_ids must include at least one account user ID' if ids.blank?

    users = account.users.where(id: ids).to_a
    missing = ids - users.map(&:id)
    raise ActiveRecord::RecordNotFound, "Account users not found: #{missing.join(', ')}" if missing.any?

    users
  end

  def inbox_payload(inbox)
    { id: inbox.id, name: inbox.name, channel_type: inbox.display_channel_type }
  end

  def member_payloads(inbox)
    inbox.members.map { |member| { id: member.id, name: member.name, email: member.email } }
  end
end
