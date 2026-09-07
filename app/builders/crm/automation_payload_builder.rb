module Crm::AutomationPayloadBuilder
  DEAL_ATTRIBUTES = %i[
    id title description amount_minor currency expected_close_on win_probability closed_at
    waiting_until waiting_reason waiting_started_at waiting_set_by_id closing_reasons external_ref
    pipeline_id stage_id owner_id creator_id team_id company_id originating_conversation_id
    originating_communication_thread_id archived_at custom_attributes
  ].freeze
  TASK_ATTRIBUTES = %i[
    id title description context_kind activity_type outcome outcome_note priority all_day start_at due_at due_on
    schedule_timezone completed_at external_ref status_id assignee_id creator_id team_id deal_id
    originating_conversation_id archived_at custom_attributes
  ].freeze

  module_function

  def deal(deal)
    {
      account: deal.account.webhook_data,
      deal: attributes_for(deal, DEAL_ATTRIBUTES).merge(primary_contact_id: deal.primary_contact_id),
      pipeline: { id: deal.pipeline.id, name: deal.pipeline.name },
      stage: { id: deal.stage.id, name: deal.stage.name, outcome: deal.stage.outcome }
    }.merge(deal_relations(deal))
  end

  def task(task)
    {
      account: task.account.webhook_data,
      task: attributes_for(task, TASK_ATTRIBUTES),
      status: { id: task.status.id, name: task.status.name, category: task.status.category }
    }.merge(task_relations(task))
  end

  def attributes_for(record, keys)
    record.attributes.symbolize_keys.slice(*keys)
  end

  def deal_relations(deal)
    contacts = deal.contacts.map(&:webhook_data)
    {
      owner: deal.owner&.webhook_data,
      creator: deal.creator&.webhook_data,
      team: team_payload(deal.team),
      company: company_payload(deal.company),
      conversation: deal.originating_conversation&.webhook_data,
      communication_thread: communication_thread_payload(deal.originating_communication_thread),
      contacts: contacts.presence
    }.compact
  end

  def task_relations(task)
    {
      assignee: task.assignee&.webhook_data,
      creator: task.creator&.webhook_data,
      team: team_payload(task.team),
      deal: task.deal && { id: task.deal.id, title: task.deal.title },
      conversation: task.originating_conversation&.webhook_data
    }.compact
  end

  def team_payload(team)
    { id: team.id, name: team.name } if team.present?
  end

  def company_payload(company)
    { id: company.id, name: company.name, domain: company.domain } if company.present?
  end

  def communication_thread_payload(thread)
    return if thread.blank?

    {
      id: thread.id,
      display_id: thread.display_id,
      contact_id: thread.contact_id,
      status: thread.status
    }
  end
end
