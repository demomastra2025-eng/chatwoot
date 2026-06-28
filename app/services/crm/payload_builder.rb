# rubocop:disable Metrics/ModuleLength
module Crm::PayloadBuilder
  module_function

  def pipeline(pipeline, include_stages: true, include_inactive_stages: true)
    deal_counts_by_stage_id = pipeline.deals.kept.group(:stage_id).count
    dialog_deal_counts_by_stage_id = pipeline_dialog_deal_counts_by_stage_id(pipeline)

    pipeline_attributes(pipeline).merge(
      deal_count: deal_counts_by_stage_id.values.sum,
      dialog_deal_count: dialog_deal_counts_by_stage_id.values.sum,
      stages: pipeline_stages_payload(
        pipeline,
        include_stages: include_stages,
        include_inactive_stages: include_inactive_stages,
        deal_counts_by_stage_id: deal_counts_by_stage_id,
        dialog_deal_counts_by_stage_id: dialog_deal_counts_by_stage_id
      )
    ).compact
  end

  def stage(stage, deal_count: nil, dialog_deal_count: nil)
    stage_attributes(stage).tap do |payload|
      payload[:deal_count] = deal_count unless deal_count.nil?
      payload[:dialog_deal_count] = dialog_deal_count unless dialog_deal_count.nil?
    end
  end

  def pipeline_attributes(pipeline)
    {
      id: pipeline.id,
      account_id: pipeline.account_id,
      name: pipeline.name,
      code: pipeline.code,
      position: pipeline.position,
      active: pipeline.active,
      default: pipeline.default,
      auto_create_deal_on_channel_contact: pipeline.auto_create_deal_on_channel_contact,
      created_at: pipeline.created_at&.iso8601,
      updated_at: pipeline.updated_at&.iso8601
    }
  end

  def stage_attributes(stage)
    {
      id: stage.id,
      account_id: stage.account_id,
      pipeline_id: stage.pipeline_id,
      name: stage.name,
      code: stage.code,
      color: stage.color,
      position: stage.position,
      outcome: stage.outcome,
      closing_reason_options: stage.closing_reason_options,
      closing_reason_required: stage.closing_reason_required,
      transition_reason_options: stage.transition_reason_options,
      transition_reason_required: stage.transition_reason_required,
      active: stage.active,
      default: stage.default,
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

  # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
  def deal(deal)
    primary_contact =
      deal.deal_contacts.detect(&:primary?)&.contact || deal.deal_contacts.first&.contact
    dialog_context = compact_dialog_context(deal)

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
      originating_communication_thread_id: deal.originating_communication_thread_id,
      originating_communication_thread_display_id: deal.originating_communication_thread&.display_id,
      dialog_id: dialog_context&.fetch(:id, nil),
      dialog_display_id: dialog_context&.fetch(:display_id, nil),
      dialog_kind: dialog_context&.fetch(:kind, nil),
      dialog_status: dialog_context&.fetch(:status, nil),
      title: deal.title,
      description: deal.description,
      amount: amount_for(deal),
      amount_minor: deal.amount_minor,
      currency: deal.currency,
      expected_close_on: deal.expected_close_on&.iso8601,
      closed_at: deal.closed_at&.iso8601,
      closing_reasons: deal.closing_reasons,
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
  # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity

  def ai_deal(deal)
    deal(deal).except(:amount_minor)
  end

  def compact_company(company)
    return if company.blank?

    {
      id: company.id,
      name: company.name,
      domain: company.domain,
      contacts_count: company_contacts_count(company),
      last_activity_at: company.last_activity_at&.iso8601
    }.compact
  end

  def company(company)
    {
      id: company.id,
      account_id: company.account_id,
      name: company.name,
      domain: company.domain,
      description: company.description,
      contacts_count: company_contacts_count(company),
      additional_attributes: company.additional_attributes,
      custom_attributes: company.custom_attributes,
      last_activity_at: company.last_activity_at&.iso8601,
      created_at: company.created_at&.iso8601,
      updated_at: company.updated_at&.iso8601
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

  def compact_dialog_context(deal)
    if deal.originating_communication_thread.present?
      return {
        display_id: deal.originating_communication_thread.display_id,
        id: deal.originating_communication_thread_id,
        kind: 'communication_thread',
        status: deal.originating_communication_thread.status
      }
    end

    return if deal.originating_conversation.blank?

    {
      display_id: deal.originating_conversation.display_id,
      id: deal.originating_conversation_id,
      kind: 'conversation',
      status: deal.originating_conversation.status
    }
  end

  def pipeline_stages_payload(pipeline, include_stages: true, include_inactive_stages: true,
                              deal_counts_by_stage_id: {}, dialog_deal_counts_by_stage_id: {})
    return unless include_stages

    stages_for_pipeline(pipeline, include_inactive_stages: include_inactive_stages).map do |crm_stage|
      stage(
        crm_stage,
        deal_count: deal_counts_by_stage_id.fetch(crm_stage.id, 0),
        dialog_deal_count: dialog_deal_counts_by_stage_id.fetch(crm_stage.id, 0)
      )
    end
  end

  def pipeline_dialog_deal_counts_by_stage_id(pipeline)
    dialog_deals_for_pipeline(pipeline).group(:stage_id).count
  end

  def dialog_deals_for_pipeline(pipeline)
    deals = pipeline.deals.kept
    direct_conversation_deals = deals.where.not(originating_conversation_id: nil)
    direct_thread_deals = deals.where.not(originating_communication_thread_id: nil)
    contact_dialog_deals = deals.where(
      id: ::Crm::DealContact
        .where(account_id: pipeline.account_id, contact_id: dialog_contact_ids(pipeline.account_id))
        .select(:deal_id)
    )

    direct_conversation_deals.or(direct_thread_deals).or(contact_dialog_deals)
  end

  def dialog_contact_ids(account_id)
    contacts_with_conversations = ::Contact.where(account_id: account_id).where(
      id: ::Conversation.where(account_id: account_id).select(:contact_id)
    )
    contacts_with_threads = ::Contact.where(account_id: account_id).where(
      id: ::CommunicationThread.where(account_id: account_id).select(:contact_id)
    )

    contacts_with_conversations.or(contacts_with_threads).select(:id)
  end

  def stages_for_pipeline(pipeline, include_inactive_stages: true)
    stages = pipeline.stages
    return stages if include_inactive_stages

    stages.select(&:active?)
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

  def company_contacts_count(company)
    return company.effective_contacts_count if company.respond_to?(:effective_contacts_count)

    company.contacts_count.to_i
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

  # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
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
      activity_type: task.activity_type,
      outcome: task.outcome,
      outcome_note: task.outcome_note,
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
  # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

  def timeline_item(item_type, payload, occurred_at:)
    {
      item_type: item_type,
      occurred_at: occurred_at&.iso8601,
      payload: payload
    }
  end
end
# rubocop:enable Metrics/ModuleLength
