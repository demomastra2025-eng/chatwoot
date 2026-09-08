class AutomationRules::CrmActionService
  def initialize(rule, account, record, entity_kind:, options: {})
    @rule = rule
    @account = account
    @record = record
    @entity_kind = entity_kind.to_s
    @changed_attributes = options[:changed_attributes]
    @execution_key = options[:execution_key]
    Current.executed_by = rule
  end

  def perform
    action_runner.perform do |action, index|
      @record.reload
      begin
        @current_action_id = action[:action_id]
        @current_action_key = @current_action_id.presence || "legacy-index:#{index}"
        send(action[:action_name], action[:action_params])
      ensure
        @current_action_id = nil
        @current_action_key = nil
      end
    end
  ensure
    Current.reset
  end

  private

  def action_runner
    @action_runner ||= AutomationRules::ActionRunner.new(
      rule: rule,
      account: account,
      execution_key: @execution_key
    )
  end

  attr_reader :account, :record, :rule, :entity_kind

  def send_webhook_event(webhook_url)
    payload = record.automation_webhook_data.merge(event: "automation_event.#{rule.event_name}")
    payload[:changed_attributes] = formatted_changed_attributes if formatted_changed_attributes.present?
    WebhookJob.perform_later(webhook_url[0], payload)
  end

  def change_deal_stage(action_params)
    transition_deal!(stage_id: normalize_required_action_param(action_params, 'change_deal_stage'))
  end

  def assign_deal_owner(action_params)
    mutate_deal!(owner_id: normalize_optional_action_param(action_params))
  end

  def assign_deal_team(action_params)
    mutate_deal!(team_id: normalize_optional_action_param(action_params))
  end

  def archive_deal(_action_params)
    archive_deal!(true)
  end

  def unarchive_deal(_action_params)
    archive_deal!(false)
  end

  def change_task_status(action_params)
    transition_task!(status_id: normalize_required_action_param(action_params, 'change_task_status'))
  end

  def assign_task_assignee(action_params)
    mutate_task!(assignee_id: normalize_optional_action_param(action_params))
  end

  def assign_task_team(action_params)
    mutate_task!(team_id: normalize_optional_action_param(action_params))
  end

  def change_task_priority(action_params)
    mutate_task!(priority: normalize_required_action_param(action_params, 'change_task_priority'))
  end

  def archive_task(_action_params)
    archive_task!(true)
  end

  def unarchive_task(_action_params)
    archive_task!(false)
  end

  def apply_touch_plan(action_params)
    touch_action_service.apply_touch_plan(action_params, action_key: @current_action_key)
  end

  def create_touch(action_params)
    touch_action_service.create_touch(action_params, action_id: @current_action_id, action_key: @current_action_key)
  end

  def send_message(action_params)
    touch_action_service.send_message(action_params, action_id: @current_action_id, action_key: @current_action_key)
  end

  def cancel_touches(action_params)
    touch_action_service.cancel_touches(action_params)
  end

  def archive_deal!(archived)
    ensure_entity_kind!('deal')

    @record = ::Crm::Deals::ArchiveService.new(
      account: account,
      deal: record,
      params: { lock_version: record.lock_version },
      archived: archived,
      actor: nil
    ).perform
  end

  def archive_task!(archived)
    ensure_entity_kind!('task')

    @record = ::Crm::Tasks::ArchiveService.new(
      account: account,
      task: record,
      params: { lock_version: record.lock_version },
      archived: archived,
      actor: nil
    ).perform
  end

  def mutate_deal!(params)
    ensure_entity_kind!('deal')

    @record = ::Crm::Deals::UpsertService.new(
      account: account,
      params: params.merge(lock_version: record.lock_version),
      deal: record,
      actor: nil
    ).perform
  end

  def mutate_task!(params)
    ensure_entity_kind!('task')

    @record = ::Crm::Tasks::UpsertService.new(
      account: account,
      params: params.merge(lock_version: record.lock_version),
      task: record,
      actor: nil
    ).perform
  end

  def transition_deal!(params)
    ensure_entity_kind!('deal')

    @record = ::Crm::Deals::StageCommandService.new(
      account: account,
      deal: record,
      params: params.merge(
        lock_version: record.lock_version,
        idempotency_key: [@execution_key, @current_action_key, 'deal-stage'].compact.join(':').presence
      ),
      actor: nil
    ).perform
  end

  def transition_task!(params)
    ensure_entity_kind!('task')

    @record = ::Crm::Tasks::StatusTransitionService.new(
      account: account,
      task: record,
      params: params.merge(lock_version: record.lock_version),
      actor: nil
    ).perform
  end

  def formatted_changed_attributes
    return if @changed_attributes.blank?

    @changed_attributes.map do |key, value|
      { key => { previous_value: value[0], current_value: value[1] } }
    end
  end

  def normalize_optional_action_param(action_params)
    value = Array(action_params).first.to_s.strip
    return nil if value.blank? || value == 'nil'

    value
  end

  def normalize_required_action_param(action_params, action_name)
    value = normalize_optional_action_param(action_params)
    raise ArgumentError, "#{action_name} requires a value" if value.blank?

    value
  end

  def ensure_entity_kind!(expected_kind)
    return if entity_kind == expected_kind

    raise ArgumentError, "#{expected_kind} automation action cannot run for #{entity_kind}"
  end

  def touch_action_service
    @touch_action_service ||= AutomationRules::TouchActionService.new(
      rule: rule,
      account: account,
      record: record,
      entity_kind: entity_kind,
      execution_key: @execution_key
    )
  end
end
