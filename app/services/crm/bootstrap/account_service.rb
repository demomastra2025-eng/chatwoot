class Crm::Bootstrap::AccountService
  DEFAULT_PIPELINE_NAME = 'Sales Pipeline'.freeze
  DEFAULT_TASK_STATUS_DEFINITIONS = [
    { code: 'todo', name: 'To do', category: 'open', default: true },
    { code: 'in_progress', name: 'In progress', category: 'in_progress', default: false },
    { code: 'done', name: 'Done', category: 'done', default: false },
    { code: 'cancelled', name: 'Cancelled', category: 'cancelled', default: false }
  ].freeze
  DEFAULT_TASK_TYPE_DEFINITIONS = [
    { code: 'task', name: 'Task', icon: 'i-lucide-list-todo', default: true },
    { code: 'call', name: 'Call', icon: 'i-lucide-phone' },
    { code: 'meeting', name: 'Meeting', icon: 'i-lucide-users' },
    { code: 'message', name: 'Message', icon: 'i-lucide-message-square' },
    { code: 'touch', name: 'Touch', icon: 'i-lucide-handshake' }
  ].freeze
  DEFAULT_TASK_OUTCOMES = {
    'task' => %w[completed not_done cancelled other],
    'call' => %w[answered no_answer busy cancelled not_done other],
    'meeting' => %w[held cancelled no_show rescheduled not_done other],
    'message' => %w[sent failed not_done other],
    'touch' => %w[completed no_answer cancelled not_done other]
  }.freeze

  attr_reader :account

  def initialize(account:)
    @account = account
  end

  def perform
    ApplicationRecord.transaction do
      bootstrap_deal_settings if account.feature_enabled?('crm_deals')
      bootstrap_task_settings if account.feature_enabled?('crm_tasks')
    end
  end

  private

  def bootstrap_deal_settings
    ensure_system_field_definitions_for('deal')
    ensure_default_pipeline
    ensure_default_stages_for_pipelines
  end

  def ensure_default_pipeline
    return if account.crm_pipelines.exists?

    account.crm_pipelines.create!(
      name: DEFAULT_PIPELINE_NAME,
      code: 'sales_pipeline',
      position: 1,
      active: true,
      default: true
    )
  end

  def ensure_default_stages_for_pipelines
    account.crm_pipelines.find_each do |pipeline|
      ::Crm::Pipelines::DefaultStageBuilder.new(pipeline: pipeline).perform
    end
  end

  def bootstrap_task_settings
    ensure_default_task_statuses
    ensure_default_task_catalogs
  end

  def ensure_default_task_statuses
    DEFAULT_TASK_STATUS_DEFINITIONS.each_with_index do |definition, index|
      status = account.crm_task_statuses.find_or_initialize_by(code: definition[:code])
      next unless status.new_record?

      status.assign_attributes(
        definition.merge(
          color: Crm::TaskStatus::STANDARD_COLORS[index] || Crm::TaskStatus::DEFAULT_COLOR,
          position: index + 1,
          active: true
        )
      )
      status.save!
    end
  end

  def ensure_default_task_catalogs
    DEFAULT_TASK_TYPE_DEFINITIONS.each_with_index do |definition, index|
      task_type = account.crm_task_types.find_or_initialize_by(code: definition[:code])
      if task_type.new_record?
        task_type.assign_attributes(definition.merge(position: index + 1, active: true))
        task_type.save!
      end
      ensure_default_task_outcomes(task_type)
    end
  end

  def ensure_default_task_outcomes(task_type)
    DEFAULT_TASK_OUTCOMES.fetch(task_type.code, []).each_with_index do |code, index|
      outcome = task_type.outcomes.find_or_initialize_by(code: code)
      next unless outcome.new_record?

      outcome.assign_attributes(
        account: account,
        name: code.humanize,
        position: index + 1,
        active: true,
        default: index.zero?,
        requires_note: %w[not_done other].include?(code)
      )
      outcome.save!
    end
  end

  def ensure_system_field_definitions_for(entity_kind)
    Crm::FieldDefinition::SYSTEM_FIELD_DEFINITIONS.fetch(entity_kind, {}).each do |key, definition|
      ensure_system_field_definition(entity_kind, key, definition)
    end
  end

  def ensure_system_field_definition(entity_kind, key, definition)
    field_definition = account.crm_field_definitions.find_or_initialize_by(
      entity_kind: entity_kind,
      key: key
    )

    if field_definition.new_record?
      field_definition.assign_attributes(definition)
    else
      field_definition.field_type = definition[:field_type]
      field_definition.options = merged_system_field_options(field_definition, definition)
    end

    field_definition.save!
  end

  def merged_system_field_options(field_definition, definition)
    options = Array(
      field_definition.options.presence || definition[:options]
    ).map(&:deep_stringify_keys)
    existing_values = options.filter_map do |option|
      option['value'].presence
    end.map(&:to_s)

    legacy_source_values(field_definition.entity_kind, field_definition.key).each do |value|
      next if existing_values.include?(value)

      options << { 'label' => value, 'value' => value }
      existing_values << value
    end

    options
  end

  def legacy_source_values(entity_kind, key)
    return [] unless entity_kind == 'deal' && key == 'source'

    account.crm_deals
           .where("crm_deals.custom_attributes ? 'source'")
           .where("NULLIF(BTRIM(crm_deals.custom_attributes ->> 'source'), '') IS NOT NULL")
           .distinct
           .pluck(Arel.sql("crm_deals.custom_attributes ->> 'source'"))
  end
end
