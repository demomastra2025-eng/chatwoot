# frozen_string_literal: true

class Captain::Tools::Copilot::GetInboxSettingsService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'get_inbox_settings'
  end

  description 'Get safe account inbox settings, working hours, members, assignment policy, and Captain auto-reply metadata'
  param :inbox_id, type: :number, desc: 'Account inbox ID', required: true

  def execute(inbox_id:)
    inbox = account.inboxes.active.includes(:members, :assignment_policy, :working_hours, captain_inbox: :captain_assistant).find(inbox_id)

    formatted_payload(
      action: 'get_inbox_settings',
      inbox: inbox_payload(inbox),
      members: member_payloads(inbox),
      working_hours: inbox.weekly_schedule,
      assignment_policy: assignment_policy_payload(inbox.assignment_policy),
      captain: captain_inbox_payload(inbox.captain_inbox)
    )
  rescue StandardError => e
    tool_failure(e)
  end

  def active?
    account_administrator?
  end

  private

  def inbox_payload(inbox)
    {
      id: inbox.id,
      name: inbox.name,
      business_name: inbox.business_name,
      channel_type: inbox.display_channel_type,
      timezone: inbox.timezone,
      enable_auto_assignment: inbox.enable_auto_assignment,
      working_hours_enabled: inbox.working_hours_enabled,
      out_of_office_message: inbox.out_of_office_message,
      allow_messages_after_resolved: inbox.allow_messages_after_resolved
    }.compact
  end

  def member_payloads(inbox)
    inbox.members.map { |member| { id: member.id, name: member.name, email: member.email } }
  end

  def assignment_policy_payload(policy)
    return nil if policy.blank?

    {
      id: policy.id,
      name: policy.name,
      enabled: policy.enabled,
      assignment_order: policy.assignment_order,
      conversation_priority: policy.conversation_priority,
      assignment_delay_minutes: policy.assignment_delay_minutes,
      max_open_conversations: policy.max_open_conversations,
      monthly_new_client_quota: policy.monthly_new_client_quota,
      sticky_owner_enabled: policy.sticky_owner_enabled,
      sticky_owner_duration_days: policy.sticky_owner_duration_days
    }
  end

  def captain_inbox_payload(captain_inbox)
    return { enabled: false } if captain_inbox.blank?

    {
      enabled: true,
      assistant_id: captain_inbox.captain_assistant_id,
      assistant_name: captain_inbox.captain_assistant&.name,
      auto_reply_mode: captain_inbox.auto_reply_mode,
      auto_reply_allowed_now: captain_inbox.auto_reply_allowed_now?,
      reply_to_open_conversations: captain_inbox.reply_to_open_conversations?
    }
  end
end
