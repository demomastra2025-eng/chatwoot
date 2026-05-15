# frozen_string_literal: true

class Captain::Tools::Copilot::SetInboxAssignmentPolicyService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'set_inbox_assignment_policy'
  end

  description 'Attach or replace the assignment policy for one account inbox'
  param :inbox_id, type: :number, desc: 'Account inbox ID', required: true
  param :assignment_policy_id, type: :number, desc: 'Account assignment policy ID to attach to the inbox', required: true

  def execute(inbox_id:, assignment_policy_id:)
    inbox = account.inboxes.active.find(inbox_id)
    policy = account.assignment_policies.find(assignment_policy_id)

    InboxAssignmentPolicy.transaction do
      inbox.inbox_assignment_policy&.destroy!
      inbox.create_inbox_assignment_policy!(assignment_policy: policy)
      inbox.reload
    end

    formatted_payload(
      action: 'set_inbox_assignment_policy',
      inbox: {
        id: inbox.id,
        name: inbox.name,
        channel_type: inbox.display_channel_type
      },
      assignment_policy: policy_payload(inbox.assignment_policy)
    )
  rescue StandardError => e
    tool_failure(e)
  end

  def active?
    account_administrator?
  end

  private

  def policy_payload(policy)
    return nil if policy.blank?

    {
      id: policy.id,
      name: policy.name,
      enabled: policy.enabled,
      assignment_order: policy.assignment_order,
      conversation_priority: policy.conversation_priority,
      fair_distribution_limit: policy.fair_distribution_limit,
      fair_distribution_window: policy.fair_distribution_window
    }
  end
end
