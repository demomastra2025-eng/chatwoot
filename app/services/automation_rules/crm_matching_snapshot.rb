class AutomationRules::CrmMatchingSnapshot
  SNAPSHOT_VERSION = 2
  WEBHOOK_KEYS_BY_KIND = {
    'deal' => %w[account deal pipeline stage owner creator team company conversation communication_thread contacts],
    'task' => %w[account task status assignee creator team deal conversation]
  }.freeze

  def self.build(record)
    entity_kind = entity_kind_for(record)
    return if entity_kind.blank?

    catalog = AutomationRules::CrmFieldCatalog.new(account: record.account, entity_kind: entity_kind)
    standard_values = catalog.standard_field_keys.index_with do |key|
      record.public_send(key)
    end
    custom_values = catalog.custom_field_keys.index_with do |key|
      record.custom_attributes.to_h[key]
    end

    {
      snapshot_version: SNAPSHOT_VERSION,
      entity_kind: entity_kind,
      matcher_data: {
        entity_kind => standard_values.merge(custom_attributes: custom_values)
      },
      webhook_data: record.automation_webhook_data
    }
  end

  def self.webhook_data_from(snapshot, entity_kind:)
    data = snapshot.to_h.with_indifferent_access
    return unless data[:snapshot_version].to_i == SNAPSHOT_VERSION
    return unless data[:entity_kind].to_s == entity_kind.to_s

    payload = data[:webhook_data]
    return unless payload.is_a?(Hash)

    allowed_keys = WEBHOOK_KEYS_BY_KIND.fetch(entity_kind.to_s, [])
    payload.with_indifferent_access.slice(*allowed_keys).deep_symbolize_keys
  end

  def self.entity_kind_for(record)
    return 'deal' if record.is_a?(::Crm::Deal)
    return 'task' if record.is_a?(::Crm::Task)
  end
  private_class_method :entity_kind_for
end
