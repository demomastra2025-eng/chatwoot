# == Schema Information
#
# Table name: automation_rules
#
#  id          :bigint           not null, primary key
#  actions     :jsonb            not null
#  active      :boolean          default(TRUE), not null
#  conditions  :jsonb            not null
#  description :text
#  event_name  :string           not null
#  name        :string           not null
#  created_at  :datetime         not null
#  updated_at  :datetime         not null
#  account_id  :bigint           not null
#
# Indexes
#
#  index_automation_rules_on_account_id  (account_id)
#
# rubocop:disable Metrics/ClassLength
class AutomationRule < ApplicationRecord
  include AccountStorageLimitable

  CONVERSATION_EVENT_NAMES = %w[
    conversation_created
    conversation_updated
    conversation_resolved
    conversation_opened
    conversation_pending
    conversation_transferred_to_ai
    message_created
  ].freeze
  DEAL_EVENT_NAMES = %w[
    deal_created
    deal_updated
    deal_stage_changed
    deal_archived
    deal_unarchived
  ].freeze
  TASK_EVENT_NAMES = %w[
    task_created
    task_updated
    task_status_changed
    task_archived
    task_unarchived
  ].freeze
  CRM_EVENT_NAMES = (DEAL_EVENT_NAMES + TASK_EVENT_NAMES).freeze
  APPOINTMENT_EVENT_NAMES = %w[
    appointment_created
    appointment_updated
    appointment_cancelled
    appointment_completed
  ].freeze
  SUPPORTED_EVENT_NAMES = (
    CONVERSATION_EVENT_NAMES +
    DEAL_EVENT_NAMES +
    TASK_EVENT_NAMES +
    APPOINTMENT_EVENT_NAMES
  ).freeze
  CONVERSATION_ACTION_ATTRIBUTES = %w[
    send_message add_label remove_label send_email_to_team assign_team assign_agent remove_assigned_agent remove_assigned_team
    send_webhook_event mute_conversation
    send_attachment change_status resolve_conversation open_conversation pending_conversation snooze_conversation change_priority
    send_email_transcript add_private_note apply_touch_plan create_touch cancel_touches
  ].freeze
  APPOINTMENT_ACTION_ATTRIBUTES = %w[
    send_webhook_event
    change_appointment_status
    cancel_appointment_payment
    send_message
    apply_touch_plan
    create_touch
    cancel_touches
  ].freeze
  DEAL_ACTION_ATTRIBUTES = %w[
    send_webhook_event
    change_deal_stage
    assign_deal_owner
    assign_deal_team
    archive_deal
    unarchive_deal
    send_message
    apply_touch_plan
    create_touch
    cancel_touches
  ].freeze
  STAGE_REFERENCE_ERROR_CODE = 'ARCHIVED_OR_DELETED_STAGE_REFERENCE'.freeze
  STAGE_REFERENCE_ERROR_MESSAGE = 'Referenced follow-up stage is archived or deleted. Select an active stage before saving this automation.'.freeze
  LEGACY_TOUCH_PLAN_ACTION = 'apply_touch_plan'.freeze
  LEGACY_TOUCH_PLAN_CANCEL_ACTION = 'cancel_touches'.freeze
  LEGACY_TOUCH_PLAN_ACTION_ERROR = [
    'Touch plans are only supported by existing legacy automation rules. ',
    'Use create_touch and plan-independent cancel_touches actions instead.'
  ].join.freeze
  TASK_ACTION_ATTRIBUTES = %w[
    send_webhook_event
    change_task_status
    assign_task_assignee
    assign_task_team
    change_task_priority
    archive_task
    unarchive_task
    send_message
    apply_touch_plan
    create_touch
    cancel_touches
  ].freeze
  CONVERSATION_CONDITION_ATTRIBUTES = %w[
    content email country_code status message_type browser_language assignee_id team_id referer city company inbox_id
    mail_subject phone_number priority conversation_language labels private_note
  ].freeze
  APPOINTMENT_CONDITION_ATTRIBUTES = %w[
    status payment_status appointment_type source starts_at_weekday starts_at_time service_id
  ].freeze

  include Rails.application.routes.url_helpers
  include Reauthorizable

  belongs_to :account
  has_many :touch_plan_enrollments, dependent: :nullify
  has_many_attached :files
  account_storage_attachments :files

  validate :json_conditions_format
  validate :json_actions_format
  validate :event_name_supported
  validate :feature_enabled_for_event
  validate :appointment_condition_operators_supported
  validate :appointment_condition_values_supported
  validate :appointment_action_params_supported
  validate :conversation_action_params_supported
  validate :crm_condition_operators_supported
  validate :crm_action_params_supported
  validate :crm_stage_references_active
  validate :new_touch_plan_actions_not_supported
  validate :execution_schedule_supported
  validate :query_operator_presence
  validate :query_operator_value
  validates :account_id, presence: true

  before_validation :normalize_action_ids
  before_destroy :cancel_live_touch_enrollments, prepend: true
  after_update_commit :reauthorized!, if: -> { saved_change_to_conditions? }
  after_update_commit :reconcile_live_touch_enrollments, if: -> { saved_change_to_actions? || saved_change_to_active? }
  after_update_commit :backfill_live_appointment_enrollments,
                      if: -> { saved_change_to_active? && active? && event_name == 'appointment_created' }

  scope :active, -> { where(active: true) }

  def conditions_attributes
    return APPOINTMENT_CONDITION_ATTRIBUTES if appointment_event?
    return crm_condition_catalog.standard_field_keys if crm_event?
    return CONVERSATION_CONDITION_ATTRIBUTES if conversation_event?

    []
  end

  def actions_attributes
    return appointment_actions_attributes if appointment_event?
    return crm_actions_attributes if crm_event?
    return CONVERSATION_ACTION_ATTRIBUTES if conversation_event?

    []
  end

  def public_actions_attributes
    actions_attributes - [LEGACY_TOUCH_PLAN_ACTION]
  end

  def appointment_event?
    event_name.in?(APPOINTMENT_EVENT_NAMES)
  end

  def crm_event?
    event_name.in?(CRM_EVENT_NAMES)
  end

  def crm_entity_kind
    return 'deal' if event_name.in?(DEAL_EVENT_NAMES)
    return 'task' if event_name.in?(TASK_EVENT_NAMES)
  end

  def file_base_data
    files.map do |file|
      {
        id: file.id,
        automation_rule_id: id,
        file_type: file.content_type,
        account_id: account_id,
        file_url: url_for(file),
        blob_id: file.blob_id,
        filename: file.filename.to_s
      }
    end
  end

  def execution_signature
    OpenSSL::Digest::SHA256.hexdigest(
      {
        event_name: event_name,
        conditions: conditions,
        actions: actions,
        execution_schedule: execution_schedule
      }.to_json
    )
  end

  private

  def normalize_action_ids
    existing_actions = actions_in_database
    seen_action_ids = Set.new
    self.actions = Array(actions).each_with_index.map do |raw_action, index|
      action = raw_action.to_h.deep_stringify_keys
      next action unless action['action_name'].in?(%w[create_touch send_message])

      action_id = action['action_id'].presence || existing_actions[index].to_h.deep_stringify_keys['action_id'].presence
      action_id = SecureRandom.uuid if action_id.blank? || seen_action_ids.include?(action_id)
      action['action_id'] = action_id
      seen_action_ids << action_id
      action
    end
  end

  def actions_in_database
    value = attribute_in_database('actions')
    value = JSON.parse(value) if value.is_a?(String)
    Array(value)
  rescue JSON::ParserError
    []
  end

  def execution_schedule_supported
    schedule = execution_schedule.to_h.with_indifferent_access
    return if schedule.blank?

    if schedule[:timing_mode].blank?
      errors.add(:execution_schedule, 'timing mode is required')
      return
    end

    return validate_immediate_execution_schedule(schedule) if schedule[:timing_mode] == 'immediate'

    validate_execution_timezone(schedule)
    case schedule[:timing_mode]
    when 'absolute'
      validate_absolute_execution_schedule(schedule)
    when 'relative'
      validate_relative_execution_schedule(schedule)
    else
      errors.add(:execution_schedule, 'timing mode is not supported')
    end
  end

  def validate_execution_timezone(schedule)
    timezone = schedule[:timezone].presence || account&.reporting_timezone.presence || 'UTC'
    errors.add(:execution_schedule, 'timezone is invalid') unless timezone.in?(TZInfo::Timezone.all_identifiers)
  end

  def validate_immediate_execution_schedule(schedule)
    return if (schedule.keys.map(&:to_s) - ['timing_mode']).none?

    errors.add(:execution_schedule, 'immediate timing cannot include schedule fields')
  end

  def validate_absolute_execution_schedule(schedule)
    if schedule.values_at(:relative_anchor, :relative_offset_seconds, :relative_time_mode, :relative_time_of_day).any?(&:present?)
      errors.add(:execution_schedule, 'absolute timing cannot include relative fields')
    end
    Time.iso8601(schedule[:scheduled_at].to_s)
  rescue ArgumentError
    errors.add(:execution_schedule, 'scheduled_at must be an ISO 8601 timestamp')
  end

  def validate_relative_execution_schedule(schedule)
    errors.add(:execution_schedule, 'relative timing cannot include scheduled_at') if schedule[:scheduled_at].present?
    anchor = schedule[:relative_anchor].to_s
    errors.add(:execution_schedule, 'relative anchor is not supported for this event') unless anchor.in?(execution_relative_anchors)

    Integer(schedule[:relative_offset_seconds])
    validate_relative_execution_time(schedule)
  rescue ArgumentError, TypeError
    errors.add(:execution_schedule, 'relative offset seconds must be an integer')
  end

  def validate_relative_execution_time(schedule)
    time_mode = schedule[:relative_time_mode].presence || Reminder::RELATIVE_TIME_MODE_INHERIT_ANCHOR_TIME
    errors.add(:execution_schedule, 'relative time mode is invalid') unless time_mode.in?(Reminder::RELATIVE_TIME_MODES)
    return unless time_mode == Reminder::RELATIVE_TIME_MODE_FIXED_TIME_OF_DAY
    return if schedule[:relative_time_of_day].to_s.match?(Reminder::RELATIVE_TIME_OF_DAY_FORMAT)

    errors.add(:execution_schedule, 'relative time of day must use HH:MM format')
  end

  def execution_relative_anchors
    return Reminder::CONVERSATION_RELATIVE_ANCHORS if conversation_event?
    return Reminder::RELATIVE_ANCHORS.grep(/^appointment\./) if appointment_event?
    return Reminder::RELATIVE_ANCHORS.grep(/^deal\./) if crm_entity_kind == 'deal'
    return Reminder::RELATIVE_ANCHORS.grep(/^task\./) if crm_entity_kind == 'task'

    []
  end

  def reconcile_live_touch_enrollments
    Reminders::ReconcileSourceEnrollmentsJob.perform_later('AutomationRule', id)
  end

  def backfill_live_appointment_enrollments
    Reminders::BackfillAutomationRuleEnrollmentsJob.perform_later(id, updated_at)
  end

  def cancel_live_touch_enrollments
    touch_plan_enrollments.find_each do |enrollment|
      Reminders::CancelEnrollmentService.new(
        enrollment: enrollment,
        reason: 'live automation action was deleted'
      ).perform
    end
  end

  # rubocop:disable Metrics/CyclomaticComplexity
  def json_conditions_format
    return if conditions.blank? || !supported_event_name?

    attributes = conditions.map { |obj, _| obj['attribute_key'] }
    conditions = attributes - conditions_attributes
    conditions -= account.custom_attribute_definitions.pluck(:attribute_key) if conversation_event?
    conditions -= appointment_condition_catalog.custom_field_keys if appointment_event?
    conditions -= crm_condition_catalog.custom_field_keys if crm_event?
    errors.add(:conditions, "Automation conditions #{conditions.join(',')} not supported.") if conditions.any?
  end
  # rubocop:enable Metrics/CyclomaticComplexity

  def json_actions_format
    return if actions.blank? || !supported_event_name?

    attributes = actions.map { |obj, _| obj['action_name'] }
    actions = attributes - actions_attributes

    errors.add(:actions, "Automation actions #{actions.join(',')} not supported.") if actions.any?
  end

  def appointment_condition_operators_supported
    return unless appointment_event?
    return if conditions.blank?

    unsupported_conditions = conditions.filter_map do |condition|
      key = condition['attribute_key'].to_s
      operator = condition['filter_operator'].to_s
      next unless appointment_condition_catalog.supported_attribute?(key)
      next if appointment_condition_catalog.operator_supported?(key, operator)

      "#{key}:#{operator}"
    end

    return if unsupported_conditions.blank?

    errors.add(:conditions, "Automation condition operators #{unsupported_conditions.join(',')} not supported.")
  end

  def appointment_condition_values_supported
    return unless appointment_event?
    return if conditions.blank?

    unsupported_conditions = conditions.filter_map do |condition|
      key = condition['attribute_key'].to_s
      next unless appointment_condition_catalog.standard_field?(key)
      next if appointment_condition_catalog.values_supported?(key, condition['values'])

      key
    end

    return if unsupported_conditions.blank?

    errors.add(:conditions, "Automation condition values #{unsupported_conditions.uniq.join(',')} not supported.")
  end

  def crm_condition_operators_supported
    return unless crm_event?
    return if conditions.blank?

    unsupported_conditions = conditions.filter_map do |condition|
      key = condition['attribute_key'].to_s
      operator = condition['filter_operator'].to_s
      next unless crm_condition_catalog.supported_attribute?(key)
      next if crm_condition_catalog.operator_supported?(key, operator)

      "#{key}:#{operator}"
    end

    return if unsupported_conditions.blank?

    errors.add(:conditions, "Automation condition operators #{unsupported_conditions.join(',')} not supported.")
  end

  def query_operator_presence
    return if conditions.blank?

    operators = conditions.select { |obj, _| obj['query_operator'].nil? }
    errors.add(:conditions, 'Automation conditions should have query operator.') if operators.length > 1
  end

  # This validation ensures logical operators are being used correctly in automation conditions.
  # And we don't push any unsanitized query operators to the database.
  def query_operator_value
    conditions.each do |obj|
      validate_single_condition(obj)
    end
  end

  def validate_single_condition(condition)
    query_operator = condition['query_operator']

    return if query_operator.nil?
    return if query_operator.empty?

    operator = query_operator.upcase
    errors.add(:conditions, 'Query operator must be either "AND" or "OR"') unless %w[AND OR].include?(operator)
  end

  def appointment_condition_catalog
    @appointment_condition_catalog ||= AutomationRules::AppointmentFieldCatalog.new(account: account)
  end

  def crm_condition_catalog
    @crm_condition_catalog ||= AutomationRules::CrmFieldCatalog.new(
      account: account,
      entity_kind: crm_entity_kind
    )
  end

  def appointment_actions_attributes
    actions = APPOINTMENT_ACTION_ATTRIBUTES.dup
    actions.delete('cancel_appointment_payment') unless account&.feature_enabled?('scheduling_finance')
    actions
  end

  def crm_actions_attributes
    crm_entity_kind == 'deal' ? DEAL_ACTION_ATTRIBUTES : TASK_ACTION_ATTRIBUTES
  end

  def appointment_action_params_supported
    return unless appointment_event?
    return if actions.blank?

    unsupported_actions = actions.filter_map do |action|
      action_name = action['action_name'].to_s
      next unless actions_attributes.include?(action_name)
      next if appointment_action_params_supported?(action_name, action['action_params'])

      action_name
    end

    return if unsupported_actions.blank?

    errors.add(:actions, "Automation action parameters #{unsupported_actions.join(',')} not supported.")
  end

  def conversation_action_params_supported
    return unless conversation_event?
    return if actions.blank?

    unsupported_actions = actions.filter_map do |action|
      action_name = action['action_name'].to_s
      next unless actions_attributes.include?(action_name)
      next if conversation_action_params_supported?(action_name, action['action_params'])

      action_name
    end

    return if unsupported_actions.blank?

    errors.add(:actions, "Automation action parameters #{unsupported_actions.join(',')} not supported.")
  end

  def crm_action_params_supported
    return unless crm_event?
    return if actions.blank?

    unsupported_actions = actions.filter_map do |action|
      action_name = action['action_name'].to_s
      next unless actions_attributes.include?(action_name)
      next if crm_action_params_supported?(action_name, action['action_params'])

      action_name
    end

    return if unsupported_actions.blank?

    errors.add(:actions, "Automation action parameters #{unsupported_actions.join(',')} not supported.")
  end

  def appointment_action_params_supported?(action_name, action_params)
    case action_name
    when 'change_appointment_status'
      Scheduling::Constants::APPOINTMENT_STATUSES.include?(normalized_action_param(action_params))
    when 'apply_touch_plan'
      touch_plan_action_params_supported?(action_params, 'appointment')
    when 'create_touch', 'send_message'
      create_touch_action_params_supported?(action_params)
    when 'cancel_touches'
      cancel_touches_action_params_supported?(action_params, 'appointment')
    else
      true
    end
  end

  # rubocop:disable Metrics/CyclomaticComplexity, Metrics/MethodLength
  def crm_action_params_supported?(action_name, action_params)
    case action_name
    when 'change_deal_stage'
      normalized_action_param(action_params).present?
    when 'assign_deal_owner', 'assign_task_assignee'
      optional_reference_supported?(account.users, action_params)
    when 'assign_deal_team', 'assign_task_team'
      optional_reference_supported?(account.teams, action_params)
    when 'change_task_status'
      account.crm_task_statuses.active.exists?(id: normalized_action_param(action_params))
    when 'change_task_priority'
      normalized_action_param(action_params).in?(::Crm::Task::PRIORITIES)
    when 'apply_touch_plan'
      touch_plan_action_params_supported?(action_params, crm_entity_kind)
    when 'create_touch', 'send_message'
      create_touch_action_params_supported?(action_params)
    when 'cancel_touches'
      cancel_touches_action_params_supported?(action_params, crm_entity_kind)
    else
      true
    end
  end
  # rubocop:enable Metrics/CyclomaticComplexity, Metrics/MethodLength

  def conversation_action_params_supported?(action_name, action_params)
    case action_name
    when 'apply_touch_plan'
      touch_plan_action_params_supported?(action_params, 'conversation')
    when 'create_touch'
      create_touch_action_params_supported?(action_params)
    when 'send_message'
      legacy_send_message_params_supported?(action_params) || create_touch_action_params_supported?(action_params)
    when 'cancel_touches'
      cancel_touches_action_params_supported?(action_params, 'conversation')
    else
      true
    end
  end

  def legacy_send_message_params_supported?(action_params)
    return true if action_params.is_a?(Array)

    action_params.is_a?(Hash) && action_params['message'].present?
  end

  def new_touch_plan_actions_not_supported
    current_actions = legacy_touch_plan_actions(actions)
    return if current_actions.blank? || errors[:actions].present?
    return if persisted_legacy_touch_plan_actions_unchanged?(current_actions)

    errors.add(:actions, LEGACY_TOUCH_PLAN_ACTION_ERROR)
  end

  def persisted_legacy_touch_plan_actions_unchanged?(current_actions)
    persisted? &&
      event_name == attribute_in_database('event_name') &&
      current_actions == legacy_touch_plan_actions(attribute_in_database('actions'))
  end

  def legacy_touch_plan_actions(value)
    Array(value).select do |action|
      action_name = action['action_name'].to_s
      next true if action_name == LEGACY_TOUCH_PLAN_ACTION
      next false unless action_name == LEGACY_TOUCH_PLAN_CANCEL_ACTION

      normalized_cancel_touches_plan_param(action['action_params']).present?
    end
  end

  def crm_stage_references_active
    return unless crm_entity_kind == 'deal'
    return if account.blank?
    return if deactivating_without_definition_changes?

    validate_crm_stage_condition_references
    validate_crm_stage_action_references
  end

  def deactivating_without_definition_changes?
    return false unless persisted?
    return false unless active == false

    (changed_attribute_names_to_save.map(&:to_s) - ['active']).blank?
  end

  def validate_crm_stage_condition_references
    Array(conditions).each_with_index do |condition, condition_index|
      next unless condition['attribute_key'].to_s == 'stage_id'
      next if condition['filter_operator'].to_s.in?(%w[is_present is_not_present])

      Array(condition['values']).each_with_index do |value, value_index|
        next if value.to_s.strip.blank?
        next if active_crm_stage_reference?(value)

        add_stage_reference_error(:conditions, "conditions[#{condition_index}].values[#{value_index}]")
      end
    end
  end

  def validate_crm_stage_action_references
    Array(actions).each_with_index do |action, action_index|
      next unless action['action_name'].to_s == 'change_deal_stage'

      value = normalized_action_param(action['action_params'])
      next if value.blank?
      next if active_crm_stage_reference?(value)

      add_stage_reference_error(:actions, "actions[#{action_index}].action_params[0]")
    end
  end

  def active_crm_stage_reference?(value)
    stage_id = normalized_reference_id(value)
    return false if stage_id.blank?

    account.crm_stages.active.exists?(id: stage_id)
  end

  def normalized_reference_id(value)
    value = value.to_s.strip
    return if value.blank?
    return unless value.match?(/\A\d+\z/)

    value
  end

  def add_stage_reference_error(attribute, path)
    errors.add(
      attribute,
      :archived_or_deleted_stage_reference,
      message: STAGE_REFERENCE_ERROR_MESSAGE,
      code: STAGE_REFERENCE_ERROR_CODE,
      path: path
    )
  end

  def touch_plan_action_params_supported?(action_params, entity_kind)
    reminder_group = account.reminder_groups.kept.find_by(id: normalized_action_param(action_params))
    reminder_group.present? && reminder_group.entity_kind_supported?(entity_kind)
  end

  def cancel_touches_action_params_supported?(action_params, entity_kind)
    value = normalized_cancel_touches_plan_param(action_params)
    return true if value.blank?

    reminder_group = account.reminder_groups.kept.find_by(id: value)
    reminder_group.present? && reminder_group.entity_kind_supported?(entity_kind)
  end

  def create_touch_action_params_supported?(action_params)
    params = normalized_action_hash(action_params)
    return false if params.blank?
    return false unless create_touch_content_supported?(params)
    return false unless create_touch_timing_supported?(params)
    return false unless create_touch_post_delivery_action_supported?(params)

    true
  end

  def create_touch_post_delivery_action_supported?(params)
    action = params[:post_delivery_action].to_s.presence
    return true if action.blank?
    return false unless conversation_event?
    return false unless action.in?(Reminder::POST_DELIVERY_ACTIONS)
    return false unless (params[:action_type].presence || 'send_message').to_s == 'send_message'

    params[:repeat_mode].blank? || params[:repeat_mode].to_s == 'once'
  end

  def create_touch_content_supported?(params)
    action_type = params[:action_type].presence || 'send_message'
    return true if action_type.to_s == 'ai_agent_wakeup'

    content_kind = params[:content_kind].presence || 'free_text'
    text_mode = resolved_touch_text_mode(params, action_type)

    return params[:instructions].to_s.strip.present? if text_mode.to_s == 'agent'
    return channel_template_content_supported?(params) if content_kind.to_s == 'channel_template'

    params[:body].to_s.strip.present? || Array(params[:attachments]).any?
  end

  def resolved_touch_text_mode(params, action_type)
    Reminders::TextModeResolver.call(
      action_type: action_type,
      body: params[:body],
      instructions: params[:instructions],
      text_mode: params[:text_mode]
    )
  end

  def channel_template_content_supported?(params)
    params[:template_params].respond_to?(:to_h) && params[:template_params].to_h.present?
  end

  def create_touch_timing_supported?(params)
    return false unless delay_minutes_supported?(params[:delay_minutes])
    return false unless repeat_mode_supported?(params[:repeat_mode])
    return false unless relative_timing_supported?(params)
    return false if fixed_time_of_day_timing?(params) && params[:relative_time_of_day].to_s !~ Reminder::RELATIVE_TIME_OF_DAY_FORMAT

    true
  end

  def relative_timing_supported?(params)
    return true unless params[:timing_mode].to_s == 'relative'
    return false if params[:relative_anchor].blank? || params[:relative_offset_seconds].blank?

    params[:repeat_mode].blank? || params[:repeat_mode].to_s == 'once'
  end

  def fixed_time_of_day_timing?(params)
    params[:timing_mode].to_s == 'relative' &&
      params[:relative_time_mode].to_s == Reminder::RELATIVE_TIME_MODE_FIXED_TIME_OF_DAY
  end

  def repeat_mode_supported?(value)
    value.blank? || value.to_s.in?(Reminder.repeat_modes.keys)
  end

  def optional_reference_supported?(scope, action_params)
    value = normalized_optional_action_param(action_params)
    return true if value.nil?

    scope.exists?(id: value)
  end

  def normalized_action_param(action_params)
    raw = first_action_param(action_params)
    raw = raw.with_indifferent_access if raw.is_a?(Hash)
    value = raw.is_a?(Hash) ? (raw[:id] || raw[:reminder_group_id] || raw[:touch_plan_id]) : raw
    value.to_s.presence
  end

  def normalized_action_hash(action_params)
    value = first_action_param(action_params)
    return unless value.is_a?(Hash)

    value.with_indifferent_access
  end

  def normalized_cancel_touches_plan_param(action_params)
    params = normalized_action_hash(action_params)
    value = if params.present?
              params[:reminder_group_id] || params[:touch_plan_id]
            else
              normalized_action_param(action_params)
            end

    value = value.to_s.strip
    return nil if value.blank? || value == 'nil'

    value
  end

  def normalized_optional_action_param(action_params)
    value = first_action_param(action_params).to_s.strip
    return nil if value.blank? || value == 'nil'

    value
  end

  def first_action_param(action_params)
    value = action_params
    value = value.to_unsafe_h if value.is_a?(ActionController::Parameters)
    value = value.to_h if value.respond_to?(:to_h) && !value.is_a?(Hash) && !value.is_a?(Array)
    return value if value.is_a?(Hash)
    return value.first if value.is_a?(Array)

    value
  end

  def delay_minutes_supported?(value)
    return true if value.blank?

    Integer(value) >= 0
  rescue ArgumentError, TypeError
    false
  end

  def conversation_event?
    event_name.in?(CONVERSATION_EVENT_NAMES)
  end

  def supported_event_name?
    event_name.in?(SUPPORTED_EVENT_NAMES)
  end

  def event_name_supported
    return unless validating_event_name_constraints?
    return if supported_event_name?

    errors.add(:event_name, 'Automation event not supported.')
  end

  # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
  def feature_enabled_for_event
    return unless validating_event_name_constraints?
    return if account.blank?
    return unless appointment_event? || crm_event?

    feature_name =
      if appointment_event?
        'scheduling'
      elsif crm_entity_kind == 'deal'
        'crm_deals'
      else
        'crm_tasks'
      end

    return if account.feature_enabled?(feature_name)

    errors.add(:event_name, "Automation event requires #{feature_name} feature.")
  end
  # rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

  def validating_event_name_constraints?
    new_record? || will_save_change_to_event_name?
  end
end
# rubocop:enable Metrics/ClassLength

AutomationRule.include_mod_with('Audit::AutomationRule')
AutomationRule.prepend_mod_with('AutomationRule')
