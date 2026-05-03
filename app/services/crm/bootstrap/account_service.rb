class Crm::Bootstrap::AccountService
  DEFAULT_PIPELINE_NAME = 'Sales Pipeline'.freeze
  DEFAULT_STAGE_DEFINITIONS = [
    { code: 'new', name: 'New', outcome: 'open' },
    { code: 'qualified', name: 'Qualified', outcome: 'open' },
    { code: 'proposal', name: 'Proposal', outcome: 'open' },
    { code: 'won', name: 'Won', outcome: 'won' },
    { code: 'lost', name: 'Lost', outcome: 'lost' }
  ].freeze
  DEFAULT_TASK_STATUS_DEFINITIONS = [
    { code: 'todo', name: 'To do', category: 'open', default: true },
    { code: 'in_progress', name: 'In progress', category: 'in_progress', default: false },
    { code: 'done', name: 'Done', category: 'done', default: false }
  ].freeze

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
  end

  def ensure_default_pipeline
    return if account.crm_pipelines.exists?

    pipeline = account.crm_pipelines.create!(
      name: DEFAULT_PIPELINE_NAME,
      code: 'sales_pipeline',
      position: 1,
      active: true,
      default: true
    )

    DEFAULT_STAGE_DEFINITIONS.each_with_index do |definition, index|
      pipeline.stages.create!(
        account: account,
        name: definition[:name],
        code: definition[:code],
        color: Crm::Stage::STANDARD_COLORS[index] || Crm::Stage::DEFAULT_COLOR,
        outcome: definition[:outcome],
        position: index + 1,
        active: true
      )
    end
  end

  def bootstrap_task_settings
    return if account.crm_task_statuses.exists?

    DEFAULT_TASK_STATUS_DEFINITIONS.each_with_index do |definition, index|
      account.crm_task_statuses.create!(
        name: definition[:name],
        code: definition[:code],
        category: definition[:category],
        color: Crm::TaskStatus::STANDARD_COLORS[index] || Crm::TaskStatus::DEFAULT_COLOR,
        position: index + 1,
        active: true,
        default: definition[:default]
      )
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
    ).map { |option| option.deep_stringify_keys }
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

    account.crm_deals.pluck(:custom_attributes).filter_map do |custom_attributes|
      custom_attributes.to_h[key].presence
    end.map(&:to_s).uniq
  end
end
