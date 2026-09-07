class Crm::Stages::ReplaceFieldRequirementsService
  def initialize(stage:, requirements:)
    @stage = stage
    @requirements = Array(requirements).map { |item| item.to_h.deep_symbolize_keys }
  end

  def perform
    stage.with_lock do
      ensure_unique_field_keys!
      stage.field_requirements.delete_all
      requirements.each { |attributes| create_requirement!(attributes) }
    end

    stage.reload
  end

  private

  attr_reader :requirements, :stage

  def ensure_unique_field_keys!
    keys = requirements.map { |attributes| attributes[:field_key].to_s.strip }
    return if keys.none?(&:blank?) && keys.uniq.length == keys.length

    raise Crm::Error.new(
      code: 'INVALID_STAGE_FIELD_REQUIREMENTS',
      message: 'Stage field requirements must contain unique non-empty field keys.',
      status: :unprocessable_content
    )
  end

  def create_requirement!(attributes)
    field_key = attributes.fetch(:field_key).to_s.strip
    field_definition = stage.account.crm_field_definitions.find_by(entity_kind: 'deal', key: field_key)
    stage.field_requirements.create!(
      account: stage.account,
      field_definition: field_definition,
      field_key: field_key,
      required: attributes.key?(:required) ? ActiveModel::Type::Boolean.new.cast(attributes[:required]) : true,
      validation: attributes[:validation].to_h,
      role_exemptions: Array(attributes[:role_exemptions])
    )
  end
end
