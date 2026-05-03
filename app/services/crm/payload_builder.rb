module Crm::PayloadBuilder
  module_function

  def pipeline(pipeline, include_stages: true)
    {
      id: pipeline.id,
      account_id: pipeline.account_id,
      name: pipeline.name,
      code: pipeline.code,
      position: pipeline.position,
      active: pipeline.active,
      default: pipeline.default,
      deal_count: pipeline.deals.count,
      stages: include_stages ? pipeline.stages.map { |crm_stage| stage(crm_stage) } : nil,
      created_at: pipeline.created_at&.iso8601,
      updated_at: pipeline.updated_at&.iso8601
    }.compact
  end

  def stage(stage)
    {
      id: stage.id,
      account_id: stage.account_id,
      pipeline_id: stage.pipeline_id,
      name: stage.name,
      code: stage.code,
      color: stage.color,
      position: stage.position,
      outcome: stage.outcome,
      active: stage.active,
      created_at: stage.created_at&.iso8601,
      updated_at: stage.updated_at&.iso8601
    }
  end

  def task_status(task_status)
    {
      id: task_status.id,
      account_id: task_status.account_id,
      name: task_status.name,
      code: task_status.code,
      color: task_status.color,
      position: task_status.position,
      category: task_status.category,
      active: task_status.active,
      default: task_status.default,
      created_at: task_status.created_at&.iso8601,
      updated_at: task_status.updated_at&.iso8601
    }
  end

  def field_definition(field_definition)
    {
      id: field_definition.id,
      account_id: field_definition.account_id,
      entity_kind: field_definition.entity_kind,
      key: field_definition.key,
      label: field_definition.label,
      description: field_definition.description,
      field_type: field_definition.field_type,
      required: field_definition.required,
      active: field_definition.active,
      system: field_definition.system?,
      position: field_definition.position,
      default_value: field_definition.default_value,
      options: field_definition.options,
      rules: field_definition.rules,
      created_at: field_definition.created_at&.iso8601,
      updated_at: field_definition.updated_at&.iso8601
    }
  end

  def deal(deal)
    primary_contact =
      deal.deal_contacts.detect(&:primary?)&.contact || deal.deal_contacts.first&.contact

    {
      id: deal.id,
      account_id: deal.account_id,
      pipeline_id: deal.pipeline_id,
      stage_id: deal.stage_id,
      owner_id: deal.owner_id,
      creator_id: deal.creator_id,
      team_id: deal.team_id,
      company_id: deal.company_id,
      originating_conversation_id: deal.originating_conversation_id,
      originating_conversation_display_id: deal.originating_conversation&.display_id,
      title: deal.title,
      description: deal.description,
      amount: amount_for(deal),
      amount_minor: deal.amount_minor,
      currency: deal.currency,
      expected_close_on: deal.expected_close_on&.iso8601,
      closed_at: deal.closed_at&.iso8601,
      position: deal.position,
      win_probability: deal.win_probability,
      external_ref: deal.external_ref,
      idempotency_key: deal.idempotency_key,
      lock_version: deal.lock_version,
      custom_attributes: deal.custom_attributes,
      archived_at: deal.archived_at&.iso8601,
      company: compact_company(deal.company),
      deal_contacts: deal.deal_contacts.map do |deal_contact|
        {
          contact_id: deal_contact.contact_id,
          primary: deal_contact.primary
        }
      end,
      primary_contact: compact_contact(primary_contact),
      primary_contact_id: deal.primary_contact_id,
      created_at: deal.created_at&.iso8601,
      updated_at: deal.updated_at&.iso8601
    }
  end

  def ai_deal(deal)
    deal(deal).except(:amount_minor)
  end

  def compact_company(company)
    return if company.blank?

    {
      id: company.id,
      name: company.name
    }
  end

  def comment(comment)
    {
      id: comment.id,
      account_id: comment.account_id,
      commentable_type: comment.commentable_type,
      commentable_id: comment.commentable_id,
      user_id: comment.user_id,
      body: comment.body,
      deleted_at: comment.deleted_at&.iso8601,
      user: compact_user(comment.user),
      created_at: comment.created_at&.iso8601,
      updated_at: comment.updated_at&.iso8601
    }
  end

  def compact_contact(contact)
    return if contact.blank?

    {
      id: contact.id,
      name: contact.name,
      email: contact.email,
      phone_number: contact.phone_number
    }
  end

  def compact_conversation(conversation)
    return if conversation.blank?

    {
      id: conversation.id,
      display_id: conversation.display_id,
      inbox_id: conversation.inbox_id,
      contact_id: conversation.contact_id,
      status: conversation.status,
      last_activity_at: conversation.last_activity_at&.iso8601,
      created_at: conversation.created_at&.iso8601,
      contact: compact_contact(conversation.contact)
    }
  end

  def amount_for(deal)
    Crm::AmountFormatter.major_from_minor(deal.amount_minor)
  end

  def compact_user(user)
    return if user.blank?

    {
      id: user.id,
      name: user.name,
      email: user.email
    }
  end

  def event(event)
    {
      id: event.id,
      account_id: event.account_id,
      eventable_type: event.eventable_type,
      eventable_id: event.eventable_id,
      actor_id: event.actor_id,
      event_type: event.event_type,
      meta: event.meta,
      created_at: event.created_at&.iso8601
    }
  end

  def task(task)
    {
      id: task.id,
      account_id: task.account_id,
      deal_id: task.deal_id,
      status_id: task.status_id,
      assignee_id: task.assignee_id,
      creator_id: task.creator_id,
      team_id: task.team_id,
      originating_conversation_id: task.originating_conversation_id,
      title: task.title,
      description: task.description,
      priority: task.priority,
      start_at: task.start_at&.iso8601,
      due_at: task.due_at&.iso8601,
      completed_at: task.completed_at&.iso8601,
      position: task.position,
      external_ref: task.external_ref,
      idempotency_key: task.idempotency_key,
      lock_version: task.lock_version,
      custom_attributes: task.custom_attributes,
      archived_at: task.archived_at&.iso8601,
      created_at: task.created_at&.iso8601,
      updated_at: task.updated_at&.iso8601
    }
  end

  def timeline_item(item_type, payload, occurred_at:)
    {
      item_type: item_type,
      occurred_at: occurred_at&.iso8601,
      payload: payload
    }
  end
end
