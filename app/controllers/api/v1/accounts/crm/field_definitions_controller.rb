class Api::V1::Accounts::Crm::FieldDefinitionsController < Api::V1::Accounts::Crm::BaseController
  before_action :set_field_definition, only: [:update, :destroy]
  before_action :ensure_relevant_feature_enabled!

  def index
    authorize ::Crm::FieldDefinition

    field_definitions = policy_scope(::Crm::FieldDefinition).ordered
    field_definitions = field_definitions.for_entity_kind(params[:entity_kind])

    render_payload(
      field_definitions.map { |field_definition| ::Crm::PayloadBuilder.field_definition(field_definition) },
      meta: { count: field_definitions.size }
    )
  end

  def create
    authorize ::Crm::FieldDefinition

    field_definition = Current.account.crm_field_definitions.new(field_definition_params)
    field_definition.position = nil unless params.key?(:position)
    field_definition.save!

    render_payload(::Crm::PayloadBuilder.field_definition(field_definition.reload), status: :created)
  end

  def update
    authorize @field_definition
    ensure_system_field_update_allowed!

    @field_definition.update!(field_definition_params)

    render_payload(::Crm::PayloadBuilder.field_definition(@field_definition.reload))
  end

  def destroy
    authorize @field_definition
    ensure_system_field_destroy_allowed!

    cleanup_service = ::Crm::FieldDefinitionValueCleanupService.new(
      account: Current.account,
      entity_kind: @field_definition.entity_kind,
      key: @field_definition.key
    )

    @field_definition.class.transaction do
      @field_definition.destroy!
      cleanup_service.perform
    end

    head :no_content
  end

  private

  def ensure_relevant_feature_enabled!
    feature_name, message = feature_requirement

    return ensure_feature_enabled!(feature_name, message) if feature_name.present?
    return if crm_foundation_enabled?

    raise ::Crm::Error.new(
      code: 'FEATURE_DISABLED',
      message: 'CRM deals, CRM tasks, or scheduling must be enabled for this account',
      status: :forbidden
    )
  end

  def ensure_system_field_update_allowed!
    return unless @field_definition.system?

    locked_attributes = locked_system_field_update_attributes
    return if locked_attributes.empty?

    raise_system_field_locked!("System field #{locked_attributes.to_sentence} cannot be changed")
  end

  def ensure_system_field_destroy_allowed!
    return unless @field_definition.system?

    raise_system_field_locked!('System fields cannot be deleted')
  end

  def locked_system_field_update_attributes
    locked_attributes = []
    locked_attributes << 'entity_kind' if params.key?(:entity_kind) && params[:entity_kind].to_s != @field_definition.entity_kind
    if params.key?(:key) &&
       params[:key].to_s.parameterize(separator: '_') != @field_definition.key
      locked_attributes << 'key'
    end
    locked_attributes << 'field_type' if params.key?(:field_type) && params[:field_type].to_s != @field_definition.field_type
    locked_attributes
  end

  def raise_system_field_locked!(message)
    raise ::Crm::Error.new(
      code: 'SYSTEM_FIELD_LOCKED',
      message: message,
      status: :unprocessable_content
    )
  end

  def crm_foundation_enabled?
    Current.account.feature_enabled?('crm_deals') ||
      Current.account.feature_enabled?('crm_tasks') ||
      Current.account.feature_enabled?('scheduling')
  end

  def feature_requirement
    case resolved_entity_kind
    when 'deal'
      ['crm_deals', 'CRM deals are not enabled for this account']
    when 'task'
      ['crm_tasks', 'CRM tasks are not enabled for this account']
    when 'appointment'
      ['scheduling', 'Scheduling is not enabled for this account']
    else
      [nil, nil]
    end
  end

  def resolved_entity_kind
    @field_definition&.entity_kind || params[:entity_kind].presence || params[:field_definition]&.[](:entity_kind)
  end

  def field_definition_params
    permitted = params.permit(
      :entity_kind,
      :key,
      :label,
      :description,
      :field_type,
      :required,
      :active,
      :position,
      options: [:label, :value],
      rules: {}
    ).to_h
    permitted['default_value'] = params[:default_value] if params.key?(:default_value)
    permitted
  end

  def set_field_definition
    @field_definition = policy_scope(::Crm::FieldDefinition).find(params[:id])
  end
end
