class Crm::RequiredFieldsInspector
  BUILT_IN_DEAL_FIELDS = {
    'title' => { label: 'Title', field_type: 'text' },
    'description' => { label: 'Description', field_type: 'textarea' },
    'owner_id' => { label: 'Owner', field_type: 'user' },
    'team_id' => { label: 'Team', field_type: 'team' },
    'company_id' => { label: 'Company', field_type: 'company' },
    'primary_contact_id' => { label: 'Primary contact', field_type: 'contact' },
    'amount_minor' => { label: 'Amount', field_type: 'currency' },
    'currency' => { label: 'Currency', field_type: 'select' },
    'expected_close_on' => { label: 'Expected close date', field_type: 'date' },
    'win_probability' => { label: 'Win probability', field_type: 'percent' }
  }.freeze

  def initialize(account:, entity_kind:, custom_attributes:, context: nil, **options)
    @account = account
    @entity_kind = entity_kind
    @custom_attributes = custom_attributes.to_h.with_indifferent_access
    @context = context
    @record = options[:record]
    @requirements = options[:requirements]
    @actor = options[:actor]
  end

  def complete?
    missing_field_details.blank?
  end

  def missing_field_details
    @missing_field_details ||= (global_required_details + stage_requirement_details).uniq { |detail| detail[:key] }
  end

  def missing_field_labels
    missing_field_details.pluck(:label)
  end

  private

  attr_reader :account, :actor, :context, :custom_attributes, :entity_kind, :record, :requirements

  def catalog
    @catalog ||= Crm::FieldCatalog.new(
      account: account,
      entity_kind: entity_kind,
      context: context
    )
  end

  def global_required_details
    catalog.missing_required_definitions(custom_attributes).map do |definition|
      { key: definition.key, label: definition.label }
    end
  end

  def stage_requirement_details
    Array(requirements).filter_map do |requirement|
      next if role_exempt?(requirement)

      value = field_value(requirement.field_key)
      reason = requirement_issue(requirement, value)
      next if reason.blank?

      field_detail(
        requirement.field_key,
        definition: requirement.field_definition,
        reason: reason,
        scope: 'stage',
        validation: requirement.validation
      )
    end
  end

  def field_detail(key, definition:, reason:, scope:, validation: {})
    metadata = BUILT_IN_DEAL_FIELDS[key.to_s] || {}
    {
      key: key.to_s,
      label: field_label(key, definition, metadata),
      field_type: field_type(definition, metadata),
      custom: definition.present? || metadata.blank?,
      reason: reason,
      scope: scope,
      validation: validation.to_h
    }
  end

  def field_label(key, definition, metadata)
    definition&.label || metadata[:label] || key.to_s.humanize
  end

  def field_type(definition, metadata)
    definition&.field_type || metadata[:field_type] || 'text'
  end

  def field_value(key)
    return record.public_send(key) if BUILT_IN_DEAL_FIELDS.key?(key.to_s) && record.respond_to?(key)

    custom_attributes[key.to_s]
  end

  def requirement_issue(requirement, value)
    return 'required' if requirement.required? && blank_value?(value)
    return if blank_value?(value)

    Crm::FieldRequirementValidator.new(
      validation: requirement.validation,
      value: value
    ).issue
  end

  def blank_value?(value)
    value.respond_to?(:empty?) ? value.empty? : value.blank?
  end

  def role_exempt?(requirement)
    role = account.account_users.find_by(user_id: actor&.id)&.role
    role.present? && Array(requirement.role_exemptions).map(&:to_s).include?(role)
  end
end
