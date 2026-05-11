class Captain::Tools::CrmCustomFieldCatalog
  SELECT_FIELD_TYPES = %w[select multiselect].freeze

  def initialize(account:, entity_kind:, context: nil)
    @account = account
    @entity_kind = entity_kind.to_s
    @context = context
  end

  def fields
    catalog.definitions.map { |definition| field_payload(definition) }
  end

  private

  attr_reader :account, :context, :entity_kind

  def catalog
    @catalog ||= ::Crm::FieldCatalog.new(account: account, entity_kind: entity_kind, context: context)
  end

  def field_payload(definition)
    {
      key: definition.key,
      label: definition.label,
      type: definition.field_type,
      required: definition.required,
      description: definition.description.presence,
      default_value: definition.default_value,
      options: options_for(definition),
      rules: definition.rules.presence
    }.compact
  end

  def options_for(definition)
    return [] unless SELECT_FIELD_TYPES.include?(definition.field_type)

    Array(definition.options).map do |option|
      if option.is_a?(Hash)
        normalized = option.with_indifferent_access
        {
          label: normalized[:label].to_s,
          value: normalized[:value].to_s
        }
      else
        {
          label: option.to_s,
          value: option.to_s
        }
      end
    end
  end
end
