# frozen_string_literal: true

class AutoAssignment::QuotaService
  pattr_initialize [:inbox!, :policy]

  def within_monthly_quota?(agent, conversation)
    return true unless monthly_quota_enabled?
    return true if conversation.contact_id.blank?
    return true if counted_for_agent?(agent, conversation.contact)

    current_count(agent) < monthly_quota
  end

  def track_assignment(agent, conversation)
    return unless monthly_quota_enabled?
    return if conversation.contact_id.blank?

    AssignmentQuotaUsage.find_or_create_by!(
      account_id: inbox.account_id,
      user_id: agent.id,
      contact_id: conversation.contact_id,
      period_start: period_start
    ) do |usage|
      usage.period_end = period_end
      usage.conversation = conversation
      usage.assignment_policy = policy
    end
  end

  private

  def monthly_quota_enabled?
    monthly_quota.positive?
  end

  def monthly_quota
    policy&.monthly_new_client_quota.to_i
  end

  def counted_for_agent?(agent, contact)
    AssignmentQuotaUsage.exists?(
      account_id: inbox.account_id,
      user_id: agent.id,
      contact_id: contact.id,
      period_start: period_start
    )
  end

  def current_count(agent)
    AssignmentQuotaUsage.where(
      account_id: inbox.account_id,
      user_id: agent.id,
      period_start: period_start
    ).count
  end

  def period_start
    Time.zone.today.beginning_of_month
  end

  def period_end
    Time.zone.today.end_of_month
  end
end
