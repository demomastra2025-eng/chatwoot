class Crm::Bootstrap::AccountService
  DEFAULT_PIPELINE_NAME = 'Sales Pipeline'.freeze
  BOOTSTRAPPED_MARKER_TTL = 1.hour
  BOOTSTRAPPED_MARKER_KEY = 'CRM_BOOTSTRAP::%<account_id>d::%<created_at>s::%<features>s'.freeze

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

  # For read-only endpoints. The full bootstrap checks (and may write) system fields, pipelines, stages
  # and task catalogs inside a transaction, which is far too much to repeat on every GET. After a
  # successful run a short-lived marker in Redis skips it; if the marker is missing (expiry, Redis
  # restart or outage) the full bootstrap simply runs again, so the defaults are still always provisioned.
  def perform_if_needed
    return if bootstrapped?

    perform
    mark_bootstrapped
  end

  private

  # The marker is tied to the account instance and to the enabled features, so a recreated account or a
  # newly enabled CRM feature never inherits a stale marker.
  def bootstrapped_marker_key
    features = %w[crm_deals crm_tasks].map { |feature| account.feature_enabled?(feature) ? '1' : '0' }.join
    format(
      BOOTSTRAPPED_MARKER_KEY,
      account_id: account.id,
      created_at: account.created_at.strftime('%s%6N'),
      features: features
    )
  end

  def bootstrapped?
    Redis::Alfred.exists?(bootstrapped_marker_key)
  rescue Redis::BaseError
    false
  end

  def mark_bootstrapped
    Redis::Alfred.set(bootstrapped_marker_key, '1', ex: BOOTSTRAPPED_MARKER_TTL.to_i)
  rescue Redis::BaseError
    nil
  end

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
    Crm::TaskCatalogs::Provisioner.new(account: account).perform
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
