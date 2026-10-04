class Crm::AutomationWebhookData
  def initialize(record)
    @record = record
  end

  def call
    return deal_payload if record.is_a?(Crm::Deal)

    task_payload
  end

  private

  attr_reader :record

  def deal_payload
    payload = {
      account: record.account.webhook_data,
      deal: deal_attributes,
      pipeline: record_attributes(record.pipeline, :name),
      stage: record_attributes(record.stage, :name, :outcome)
    }
    add_deal_relationships(payload)
    payload
  end

  def deal_attributes
    deal_value_attributes.merge(deal_reference_attributes)
  end

  def deal_value_attributes
    record_attributes(
      record,
      :title,
      :description,
      :amount_minor,
      :currency,
      :expected_close_on,
      :win_probability,
      :closed_at,
      :closing_reasons,
      :external_ref
    )
  end

  def deal_reference_attributes
    record_attributes(
      record,
      :pipeline_id,
      :stage_id,
      :owner_id,
      :creator_id,
      :team_id,
      :company_id,
      :originating_conversation_id,
      :originating_communication_thread_id,
      :primary_contact_id,
      :archived_at,
      :custom_attributes
    ).except(:id)
  end

  def add_deal_relationships(payload)
    add_deal_people(payload)
    add_deal_associations(payload)
    payload
  end

  def add_deal_people(payload)
    add_user(payload, :owner, record.owner)
    add_user(payload, :creator, record.creator)
  end

  def add_deal_associations(payload)
    add_team(payload)
    payload[:company] = record_attributes(record.company, :name, :domain) if record.company.present?
    payload[:conversation] = record.originating_conversation.webhook_data if record.originating_conversation.present?
    add_communication_thread(payload)
    payload[:contacts] = record.contacts.map(&:webhook_data) if record.contacts.exists?
  end

  def add_communication_thread(payload)
    thread = record.originating_communication_thread
    return if thread.blank?

    payload[:communication_thread] = record_attributes(thread, :display_id, :contact_id, :status)
  end

  def task_payload
    payload = {
      account: record.account.webhook_data,
      task: task_attributes,
      status: record_attributes(record.status, :name, :category)
    }
    add_user(payload, :assignee, record.assignee)
    add_user(payload, :creator, record.creator)
    add_team(payload)
    add_task_relationships(payload)
    payload
  end

  def task_attributes
    task_value_attributes.merge(task_reference_attributes)
  end

  def task_value_attributes
    record_attributes(
      record,
      :title,
      :description,
      :activity_type,
      :outcome,
      :outcome_note,
      :priority,
      :start_at,
      :due_at,
      :due_on,
      :all_day,
      :schedule_timezone,
      :completed_at,
      :cancelled_at,
      :cancellation_reason,
      :reschedule_count
    )
  end

  def task_reference_attributes
    record_attributes(
      record,
      :external_ref,
      :status_id,
      :task_type_id,
      :task_outcome_id,
      :context_kind,
      :assignee_id,
      :creator_id,
      :team_id,
      :deal_id,
      :originating_conversation_id,
      :archived_at,
      :custom_attributes
    ).except(:id)
  end

  def add_task_relationships(payload)
    payload[:deal] = record_attributes(record.deal, :title) if record.deal.present?
    payload[:conversation] = record.originating_conversation.webhook_data if record.originating_conversation.present?
  end

  def add_user(payload, key, user)
    payload[key] = user.webhook_data if user.present?
  end

  def add_team(payload)
    payload[:team] = record_attributes(record.team, :name) if record.team.present?
  end

  def record_attributes(value, *fields)
    fields.each_with_object(id: value.id) do |field, attributes|
      attributes[field] = value.public_send(field)
    end
  end
end
