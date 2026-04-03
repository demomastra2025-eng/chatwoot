class Crm::RequiredFieldsInspector
  def initialize(account:, entity_kind:, custom_attributes:, context: nil)
    @account = account
    @entity_kind = entity_kind
    @custom_attributes = custom_attributes
    @context = context
  end

  def complete?
    missing_definitions.blank?
  end

  def missing_field_details
    missing_definitions.map do |definition|
      {
        key: definition.key,
        label: definition.label
      }
    end
  end

  def missing_field_labels
    missing_field_details.pluck(:label)
  end

  private

  attr_reader :account, :context, :custom_attributes, :entity_kind

  def catalog
    @catalog ||= Crm::FieldCatalog.new(
      account: account,
      entity_kind: entity_kind,
      context: context
    )
  end

  def missing_definitions
    @missing_definitions ||= catalog.missing_required_definitions(custom_attributes)
  end
end
